#define PROFILER_FILENAME "profiler.json"
/// Interval between periodic summaries (deciseconds). Default: 10 minutes
#define PROFILER_SUMMARY_INTERVAL 6000

SUBSYSTEM_DEF(profiler)
	name = "Profiler"
	init_order = INIT_ORDER_PROFILER
	runlevels = RUNLEVELS_DEFAULT | RUNLEVEL_LOBBY
	wait = 3000
	flags = SS_NO_TICK_CHECK
	var/fetch_cost = 0
	var/write_cost = 0
	/// Whether world.Profile() is currently active
	var/profiling_active = FALSE
	/// world.time when next periodic summary is due
	var/next_summary_time = 0
	/// Cached parsed profile data (list of valid assoc entries) from latest world.Profile() call
	var/list/cached_parsed_profile
	/// world.time of last profile data cache update
	var/cached_profile_time = 0

/datum/controller/subsystem/profiler/stat_entry(msg)
	msg += "F:[round(fetch_cost,1)]ms"
	msg += "|W:[round(write_cost,1)]ms"
	msg += "|A:[profiling_active]"
	return msg

/datum/controller/subsystem/profiler/Initialize()
	StartProfiling()
	next_summary_time = world.time + PROFILER_SUMMARY_INTERVAL
	return ..()

/datum/controller/subsystem/profiler/fire()
	if(CONFIG_GET(flag/auto_profile))
		DumpFile()
	// Periodic summary
	if(world.time >= next_summary_time)
		next_summary_time = world.time + PROFILER_SUMMARY_INTERVAL
		write_periodic_summary()

/datum/controller/subsystem/profiler/Shutdown()
	write_round_report()
	if(CONFIG_GET(flag/auto_profile))
		DumpFile()
	return ..()

/datum/controller/subsystem/profiler/proc/StartProfiling()
	world.Profile(PROFILE_START)
	profiling_active = TRUE

/datum/controller/subsystem/profiler/proc/StopProfiling()
	world.Profile(PROFILE_STOP)
	profiling_active = FALSE

/datum/controller/subsystem/profiler/proc/DumpFile()
	var/timer = TICK_USAGE_REAL
	var/current_profile_data = world.Profile(PROFILE_REFRESH, format="json")
	fetch_cost = MC_AVERAGE(fetch_cost, TICK_DELTA_TO_MS(TICK_USAGE_REAL - timer))
	CHECK_TICK
	if(!length(current_profile_data)) //Would be nice to have explicit proc to check this
		stack_trace("Warning, profiling stopped manually before dump.")
	var/json_file = file("[GLOB.log_directory]/[PROFILER_FILENAME]")
	if(fexists(json_file))
		fdel(json_file)
	timer = TICK_USAGE_REAL
	WRITE_FILE(json_file, current_profile_data)
	write_cost = MC_AVERAGE(write_cost, TICK_DELTA_TO_MS(TICK_USAGE_REAL - timer))

/// Get parsed profile data, using cache if recent enough (within 50 ticks).
/// Returns list of valid entries (each with name, self, total, real, calls) or null.
/// Callers may mutate the returned list safely — it is a shallow copy.
/datum/controller/subsystem/profiler/proc/get_cached_profile(force_refresh = FALSE)
	if(!force_refresh && cached_parsed_profile && (world.time - cached_profile_time) < 50)
		return cached_parsed_profile.Copy()

	var/raw
	try
		raw = world.Profile(PROFILE_REFRESH, format="json")
	catch
		return null
	if(!length(raw))
		return null
	var/list/parsed
	try
		parsed = json_decode(raw)
	catch
		return null
	if(!islist(parsed) || !length(parsed))
		return null

	// Filter to valid numeric entries
	var/list/candidates = list()
	for(var/list/entry in parsed)
		if(length(entry) >= 5 && isnum(entry["self"]) && isnum(entry["calls"]) && entry["calls"] > 0)
			if(!isnum(entry["total"]) || !isnum(entry["real"]))
				continue
			candidates += list(entry)

	cached_parsed_profile = candidates
	cached_profile_time = world.time
	return candidates.Copy()

// =====================================================
// Periodic Summary — written every PROFILER_SUMMARY_INTERVAL
// =====================================================

/datum/controller/subsystem/profiler/proc/write_periodic_summary()
	if(!GLOB.profiler_summary_log || !SStime_track)
		return
	var/list/lines = list()
	var/round_minutes = round(world.time / 600, 0.1)
	lines += "=== PERIODIC SUMMARY [time2text(world.timeofday, "hh:mm:ss")] | round=[round_minutes]min | players=[length(GLOB.clients)] ==="
	lines += "Time dilation: current=[round(SStime_track.time_dilation_current, 0.1)]% | fast=[round(SStime_track.time_dilation_avg_fast, 0.1)]% | avg=[round(SStime_track.time_dilation_avg, 0.1)]% | slow=[round(SStime_track.time_dilation_avg_slow, 0.1)]%"
	lines += "CPU: [world.cpu]% | instances: [world.contents.len] | maptick: [round(MAPTICK_LAST_INTERNAL_TICK_USAGE, 0.1)]%"

	// Top 15 procs
	if(profiling_active)
		var/list/procs = fetch_top_procs(15)
		if(length(procs))
			lines += "-- Top 15 procs (self time) --"
			for(var/i in 1 to length(procs))
				var/list/e = procs[i]
				lines += "  [i]. [e["name"]] | self=[round(e["self"], 0.01)]ms | calls=[e["calls"]] | avg=[round(e["self"] / max(e["calls"], 1), 0.001)]ms"

	// Top 10 subsystem costs
	if(Master)
		var/list/ss_sorted = get_sorted_subsystem_costs(10)
		if(length(ss_sorted))
			lines += "-- Subsystem costs (top 10) --"
			for(var/i in 1 to length(ss_sorted))
				var/list/ss = ss_sorted[i]
				lines += "  [i]. [ss["name"]] | cost=[round(ss["cost"], 0.01)]ms | tick=[round(ss["tick"], 0.01)]% | overrun=[round(ss["overrun"], 0.01)]%"

	// Queue sizes
	lines += "-- Queue sizes --"
	lines += "  SSmachines=[length(SSmachines.processing)] | SSmobs=[length(GLOB.mob_living_list)] | SSprocessing=[length(SSprocessing.processing)] | SSfastprocess=[length(SSfastprocess.processing)] | SSobj=[length(SSobj.processing)] | SStimer=[length(SStimer.timer_id_dict)]"

	// Round stats so far
	var/list/stats = SStime_track.get_accumulated_stats()
	lines += "-- Round stats so far --"
	lines += "  Peak tidi: [round(stats["peak_time_dilation"], 0.1)]% at [stats["peak_time_dilation_worldtime"]] | Avg tidi: [stats["avg_time_dilation"]]%"
	lines += "  Peak CPU: [round(stats["peak_cpu"], 0.1)]% at [stats["peak_cpu_worldtime"]] | Avg CPU: [stats["avg_cpu"]]%"
	lines += "  Peak players: [stats["peak_players"]] | Spikes detected: [stats["spike_count"]]"
	lines += ""

	WRITE_LOG_NO_FORMAT(GLOB.profiler_summary_log, jointext(lines, "\n"))

// =====================================================
// Round-End Report — comprehensive dump at shutdown
// =====================================================

/datum/controller/subsystem/profiler/proc/write_round_report()
	if(!GLOB.log_directory || !SStime_track)
		return
	var/report_path = "[GLOB.log_directory]/auto_profiler_round_report.log"

	var/list/lines = list()
	var/round_minutes = round(world.time / 600, 0.1)
	var/list/stats = SStime_track.get_accumulated_stats()

	// === HEADER ===
	lines += "=============================================================================================="
	lines += "=== ROUND PERFORMANCE REPORT ==="
	lines += "=============================================================================================="
	lines += "Round ID: [GLOB.round_id ? GLOB.round_id : "N/A"] | Map: [SSmapping.config?.map_name] | Duration: [round_minutes] min"
	lines += "Peak players: [stats["peak_players"]] | Current players: [length(GLOB.clients)]"
	lines += "Generated: [time2text(world.timeofday, "hh:mm:ss")]"
	lines += ""

	// === ACCUMULATED STATISTICS ===
	lines += "--- Accumulated Statistics ---"
	lines += "  Time dilation:"
	lines += "    Current: [round(stats["time_dilation_current"], 0.1)]% | Fast avg: [round(stats["time_dilation_avg_fast"], 0.1)]% | Avg: [round(stats["time_dilation_avg"], 0.1)]% | Slow avg: [round(stats["time_dilation_avg_slow"], 0.1)]%"
	lines += "    Peak: [round(stats["peak_time_dilation"], 0.1)]% (at world.time=[stats["peak_time_dilation_worldtime"]]) | Round avg: [stats["avg_time_dilation"]]%"
	lines += "  CPU:"
	lines += "    Current: [world.cpu]% | Peak: [round(stats["peak_cpu"], 0.1)]% (at world.time=[stats["peak_cpu_worldtime"]]) | Round avg: [stats["avg_cpu"]]%"
	lines += "  Maptick: current=[round(MAPTICK_LAST_INTERNAL_TICK_USAGE, 0.1)]% | peak=[round(stats["peak_maptick"], 0.1)]%"
	lines += "  Samples: [stats["tidi_samples"]] (over [round_minutes] minutes)"
	lines += ""

	// === SPIKE SUMMARY ===
	lines += "--- Spike Summary ---"
	lines += "  Total spikes detected: [stats["spike_count"]]"
	if(stats["worst_spike_tidi"] > 0)
		lines += "  Worst spike: tidi=[round(stats["worst_spike_tidi"], 0.1)]% at world.time=[stats["worst_spike_worldtime"]]"
		var/list/worst_procs = stats["worst_spike_procs"]
		if(length(worst_procs))
			lines += "  Top procs during worst spike:"
			for(var/i in 1 to min(5, length(worst_procs)))
				lines += "    [i]. [worst_procs[i]]"
	else
		lines += "  No spikes detected (thresholds: minor>[SPIKE_MINOR_THRESHOLD]%, major>[SPIKE_MAJOR_THRESHOLD]%)"
	lines += ""

	// === TOP 30 PROC HOTSPOTS + CATEGORY BREAKDOWN ===
	if(profiling_active)
		var/list/all_procs = get_cached_profile(force_refresh = TRUE)
		if(length(all_procs))
			// Calculate total self time for percentage
			var/total_self = 0
			for(var/list/ep in all_procs)
				total_self += ep["self"]

			// Partial sort for top 30
			var/top_count = min(30, length(all_procs))
			for(var/i in 1 to top_count)
				var/max_idx = i
				for(var/j in (i + 1) to length(all_procs))
					if(all_procs[j]["self"] > all_procs[max_idx]["self"])
						max_idx = j
				if(max_idx != i)
					var/temp = all_procs[i]
					all_procs[i] = all_procs[max_idx]
					all_procs[max_idx] = temp

			lines += "--- Top 30 Proc Hotspots ---"
			for(var/i in 1 to top_count)
				var/list/e = all_procs[i]
				var/pct = total_self > 0 ? round((e["self"] / total_self) * 100, 0.1) : 0
				var/cat = categorize_profile_proc(e["name"])
				lines += "  [i]. [e["name"]] | self=[round(e["self"], 0.01)]ms ([pct]%) | calls=[e["calls"]] | avg=[round(e["self"] / max(e["calls"], 1), 0.001)]ms | cat=[cat]"

			// Category breakdown from ALL procs (not just top 30)
			var/list/cat_totals = list()
			for(var/list/ep in all_procs)
				var/cat = categorize_profile_proc(ep["name"])
				cat_totals[cat] = (cat_totals[cat] || 0) + ep["self"]

			lines += ""
			lines += "--- Category Breakdown ---"
			// Sort categories by total descending
			var/list/cat_keys = list()
			for(var/cat in cat_totals)
				cat_keys += cat
			for(var/i in 1 to length(cat_keys))
				var/max_idx = i
				for(var/j in (i + 1) to length(cat_keys))
					if(cat_totals[cat_keys[j]] > cat_totals[cat_keys[max_idx]])
						max_idx = j
				if(max_idx != i)
					var/temp = cat_keys[i]
					cat_keys[i] = cat_keys[max_idx]
					cat_keys[max_idx] = temp
			for(var/cat in cat_keys)
				var/pct = total_self > 0 ? round((cat_totals[cat] / total_self) * 100, 0.1) : 0
				lines += "  [cat]: [round(cat_totals[cat], 0.01)]ms ([pct]%)"
		lines += ""

	// === SUBSYSTEM COSTS (all, sorted) ===
	if(Master)
		var/list/ss_sorted = get_sorted_subsystem_costs(0) // 0 = all
		if(length(ss_sorted))
			lines += "--- Subsystem Costs (all, sorted by cost) ---"
			for(var/i in 1 to length(ss_sorted))
				var/list/ss = ss_sorted[i]
				lines += "  [i]. [ss["name"]] | cost=[round(ss["cost"], 0.01)]ms | tick=[round(ss["tick"], 0.01)]% | overrun=[round(ss["overrun"], 0.01)]% | fired=[ss["times_fired"]]"
			lines += ""

	// === ATMOSPHERE BREAKDOWN ===
	lines += "--- Atmosphere (SSair, cost=[round(SSair.cost, 0.01)]ms) ---"
	lines += "  cost_turfs=[round(SSair.cost_turfs, 0.01)]ms | cost_equalize=[round(SSair.cost_equalize, 0.01)]ms | cost_groups=[round(SSair.cost_groups, 0.01)]ms"
	lines += "  cost_highpressure=[round(SSair.cost_highpressure, 0.01)]ms | cost_hotspots=[round(SSair.cost_hotspots, 0.01)]ms | cost_superconductivity=[round(SSair.cost_superconductivity, 0.01)]ms"
	lines += "  cost_pipenets=[round(SSair.cost_pipenets, 0.01)]ms | cost_rebuilds=[round(SSair.cost_rebuilds, 0.01)]ms | cost_post_process=[round(SSair.cost_post_process, 0.01)]ms"
	lines += "  cost_atmos_machinery=[round(SSair.cost_atmos_machinery, 0.01)]ms"
	lines += "  networks=[length(SSair.networks)] | hotspots=[length(SSair.hotspots)] | high_pressure_delta=[length(SSair.high_pressure_delta)] | atmos_machinery=[length(SSair.atmos_machinery)]"
	lines += "  gas_mixes=[SSair.get_amt_gas_mixes()] / [SSair.get_max_gas_mixes()] allocated"
	lines += ""

	// === MACHINE TYPE BREAKDOWN ===
	lines += "--- Machines (processing: [length(SSmachines.processing)], all: [length(SSmachines.all_machines)], powernets: [length(SSmachines.powernets)]) ---"
	if(length(SSmachines.processing))
		var/list/machine_counts = list()
		for(var/obj/machinery/M as anything in SSmachines.processing)
			if(!M)
				continue
			var/type_name = "[M.type]"
			machine_counts[type_name] = (machine_counts[type_name] || 0) + 1
		var/list/machine_sorted = sort_assoc_by_value_desc(machine_counts)
		for(var/i in 1 to min(25, length(machine_sorted)))
			var/key = machine_sorted[i]
			lines += "  [machine_counts[key]]x [key]"
	lines += ""

	// === MOB TYPE BREAKDOWN ===
	lines += "--- Mobs (living: [length(GLOB.mob_living_list)]) ---"
	if(length(GLOB.mob_living_list))
		var/list/mob_counts = list()
		for(var/mob/living/M as anything in GLOB.mob_living_list)
			if(!M)
				continue
			var/type_name = "[M.type]"
			mob_counts[type_name] = (mob_counts[type_name] || 0) + 1
		var/list/mob_sorted = sort_assoc_by_value_desc(mob_counts)
		for(var/i in 1 to min(15, length(mob_sorted)))
			var/key = mob_sorted[i]
			lines += "  [mob_counts[key]]x [key]"
	lines += ""

	// === SSobj / SSfastprocess BREAKDOWN ===
	lines += "--- SSobj (processing: [length(SSobj.processing)]) ---"
	if(length(SSobj.processing))
		var/list/obj_counts = list()
		for(var/datum/D as anything in SSobj.processing)
			if(!D)
				continue
			var/type_name = "[D.type]"
			obj_counts[type_name] = (obj_counts[type_name] || 0) + 1
		var/list/obj_sorted = sort_assoc_by_value_desc(obj_counts)
		for(var/i in 1 to min(15, length(obj_sorted)))
			var/key = obj_sorted[i]
			lines += "  [obj_counts[key]]x [key]"
	lines += ""
	lines += "--- SSfastprocess (processing: [length(SSfastprocess.processing)]) ---"
	if(length(SSfastprocess.processing))
		var/list/fast_counts = list()
		for(var/datum/D as anything in SSfastprocess.processing)
			if(!D)
				continue
			var/type_name = "[D.type]"
			fast_counts[type_name] = (fast_counts[type_name] || 0) + 1
		var/list/fast_sorted = sort_assoc_by_value_desc(fast_counts)
		for(var/i in 1 to min(15, length(fast_sorted)))
			var/key = fast_sorted[i]
			lines += "  [fast_counts[key]]x [key]"
	lines += ""

	// === PROCESSING QUEUES ===
	lines += "--- Processing Queues ---"
	lines += "  SSmachines.processing: [length(SSmachines.processing)]"
	lines += "  SSmobs (GLOB.mob_living_list): [length(GLOB.mob_living_list)]"
	lines += "  SSprocessing: [length(SSprocessing.processing)]"
	lines += "  SSfastprocess: [length(SSfastprocess.processing)]"
	lines += "  SSobj: [length(SSobj.processing)]"
	lines += "  SStimer.timer_id_dict: [length(SStimer.timer_id_dict)]"
	lines += ""

	// === GARBAGE COLLECTOR ===
	lines += "--- Garbage Collector (SSgarbage) ---"
	lines += "  totalgcs=[SSgarbage.totalgcs] | totaldels=[SSgarbage.totaldels] | gc_ratio=[SSgarbage.totalgcs ? round(SSgarbage.totalgcs / max(SSgarbage.totalgcs + SSgarbage.totaldels, 1) * 100, 0.1) : 0]%"
	lines += "  delslasttick=[SSgarbage.delslasttick] | gcedlasttick=[SSgarbage.gcedlasttick]"
	lines += "  highest_del=[SSgarbage.highest_del_ms]ms ([SSgarbage.highest_del_type_string])"
	if(length(SSgarbage.queues))
		var/list/queue_info = list()
		for(var/i in 1 to length(SSgarbage.queues))
			queue_info += "Q[i]=[length(SSgarbage.queues[i])]"
		lines += "  Queues: [jointext(queue_info, " | ")]"
	lines += ""

	// === GENERAL STATS ===
	lines += "--- General Stats ---"
	lines += "  world.contents: [world.contents.len]"
	lines += "  world.cpu: [world.cpu]% | world.fps: [world.fps] | tick_lag: [world.tick_lag]"
	lines += "  map_tick: [round(MAPTICK_LAST_INTERNAL_TICK_USAGE, 0.1)]%"
	if(Master)
		lines += "  MC iteration: [Master.iteration] | tickdrift: [round(Master.tickdrift, 0.1)]"
	lines += ""
	lines += "=============================================================================================="

	// Write report
	var/file_ref = file(report_path)
	WRITE_FILE(file_ref, jointext(lines, "\n"))

// =====================================================
// Helper procs
// =====================================================

/// Fetch and return top N procs sorted by self time. Returns list of assoc lists.
/datum/controller/subsystem/profiler/proc/fetch_top_procs(top_n = 15)
	var/list/candidates = get_cached_profile()
	if(!length(candidates))
		return list()

	var/top_count = min(top_n, length(candidates))
	for(var/i in 1 to top_count)
		var/max_idx = i
		for(var/j in (i + 1) to length(candidates))
			if(candidates[j]["self"] > candidates[max_idx]["self"])
				max_idx = j
		if(max_idx != i)
			var/temp = candidates[i]
			candidates[i] = candidates[max_idx]
			candidates[max_idx] = temp

	candidates.len = top_count
	return candidates

/// Get sorted subsystem costs. top_n=0 returns all.
/datum/controller/subsystem/profiler/proc/get_sorted_subsystem_costs(top_n = 10)
	if(!Master)
		return list()
	var/list/ss_costs = list()
	for(var/datum/controller/subsystem/SS as anything in Master.subsystems)
		if(SS.flags & SS_NO_FIRE)
			continue
		ss_costs += list(list(
			"name" = SS.name,
			"cost" = SS.cost,
			"tick" = SS.tick_usage,
			"overrun" = SS.tick_overrun,
			"times_fired" = SS.times_fired,
		))
	var/count = top_n > 0 ? min(top_n, length(ss_costs)) : length(ss_costs)
	for(var/i in 1 to count)
		var/max_idx = i
		for(var/j in (i + 1) to length(ss_costs))
			if(ss_costs[j]["cost"] > ss_costs[max_idx]["cost"])
				max_idx = j
		if(max_idx != i)
			var/temp = ss_costs[i]
			ss_costs[i] = ss_costs[max_idx]
			ss_costs[max_idx] = temp
	if(top_n > 0 && length(ss_costs) > count)
		ss_costs.len = count
	return ss_costs

/// Sort assoc list keys by numeric values descending. Returns sorted list of keys.
/datum/controller/subsystem/profiler/proc/sort_assoc_by_value_desc(list/assoc)
	var/list/keys = list()
	for(var/key in assoc)
		keys += key
	for(var/i in 1 to length(keys))
		var/max_idx = i
		for(var/j in (i + 1) to length(keys))
			if(assoc[keys[j]] > assoc[keys[max_idx]])
				max_idx = j
		if(max_idx != i)
			var/temp = keys[i]
			keys[i] = keys[max_idx]
			keys[max_idx] = temp
	return keys
