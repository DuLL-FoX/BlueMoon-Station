SUBSYSTEM_DEF(time_track)
	name = "Time Tracking"
	wait = 10
	flags = SS_NO_TICK_CHECK
	init_order = INIT_ORDER_TIMETRACK
	runlevels = RUNLEVEL_LOBBY | RUNLEVELS_DEFAULT

	var/time_dilation_current = 0

	var/time_dilation_avg_fast = 0
	var/time_dilation_avg = 0
	var/time_dilation_avg_slow = 0

	var/first_run = TRUE

	var/last_tick_realtime = 0
	var/last_tick_byond_time = 0
	var/last_tick_tickcount = 0

	// --- Accumulated round statistics ---
	/// Peak time dilation observed this round (%)
	var/peak_time_dilation = 0
	/// world.time when peak time dilation occurred
	var/peak_time_dilation_worldtime = 0
	/// Peak CPU usage this round (%)
	var/peak_cpu = 0
	/// world.time when peak CPU occurred
	var/peak_cpu_worldtime = 0
	/// Peak maptick usage this round (%)
	var/peak_maptick = 0
	/// Peak player count this round
	var/peak_players = 0
	/// Number of time dilation samples collected
	var/total_tidi_samples = 0
	/// Sum of all time dilation samples (for average calculation)
	var/sum_tidi = 0
	/// Sum of all CPU samples
	var/sum_cpu = 0

	// --- Spike tracking ---
	/// Total spike events detected this round
	var/spike_count = 0
	/// world.time of last minor spike capture
	var/last_spike_time = 0
	/// world.time of last major spike capture
	var/last_major_spike_time = 0
	/// Highest time dilation during any spike
	var/worst_spike_tidi = 0
	/// world.time of worst spike
	var/worst_spike_worldtime = 0
	/// Top procs captured during worst spike (list of name:self:calls strings)
	var/list/worst_spike_procs

/datum/controller/subsystem/time_track/Initialize(start_timeofday)
	. = ..()
	GLOB.perf_log = "[GLOB.log_directory]/perf-[GLOB.round_id ? GLOB.round_id : "NULL"]-[SSmapping.config?.map_name].csv"
	GLOB.profiler_spike_log = "[GLOB.log_directory]/auto_profiler_spikes.log"
	GLOB.profiler_summary_log = "[GLOB.log_directory]/auto_profiler_summaries.log"
	log_perf(
		list(
			"time",
			"players",
			"cpu",
			"instances",
			"tidi",
			"tidi_fastavg",
			"tidi_avg",
			"tidi_slowavg",
			"maptick",
			"num_timers",
			"ss_machines_cost",
			"ss_mobs_cost",
			"ss_lighting_cost",
			"ss_garbage_cost",
			"ss_tgui_cost",
			"ss_timer_cost",
			"air_turf_cost",
			"air_turf_thread_time",
			"air_equalize_cost",
			"air_post_process_cost",
			"air_eg_cost",
			"air_highpressure_cost",
			"air_hotspots_cost",
			"air_heat_spread_cost",
			"air_pipenets_cost",
			"air_rebuilds_cost",
			"air_amt_gas_mixes",
			"air_alloc_gas_mixes",
			"air_hotspot_count",
			"air_network_count",
			"air_delta_count",
		)
	)

/datum/controller/subsystem/time_track/fire()

	var/current_realtime = REALTIMEOFDAY
	var/current_byondtime = world.time
	var/current_tickcount = world.time/world.tick_lag
	GLOB.glide_size_multiplier = (current_byondtime - last_tick_byond_time) / (current_realtime - last_tick_realtime)

	if(times_fired % 10)	// everything else is once every 10 seconds
		return

	if (!first_run)
		var/tick_drift = max(0, (((current_realtime - last_tick_realtime) - (current_byondtime - last_tick_byond_time)) / world.tick_lag))

		time_dilation_current = tick_drift / (current_tickcount - last_tick_tickcount) * 100

		time_dilation_avg_fast = MC_AVERAGE_FAST(time_dilation_avg_fast, time_dilation_current)
		time_dilation_avg = MC_AVERAGE(time_dilation_avg, time_dilation_avg_fast)
		time_dilation_avg_slow = MC_AVERAGE_SLOW(time_dilation_avg_slow, time_dilation_avg)
	else
		first_run = FALSE
	last_tick_realtime = current_realtime
	last_tick_byond_time = current_byondtime
	last_tick_tickcount = current_tickcount

	// --- Accumulate round statistics ---
	var/current_players = length(GLOB.clients)
	var/current_cpu = world.cpu
	var/current_maptick = MAPTICK_LAST_INTERNAL_TICK_USAGE

	total_tidi_samples++
	sum_tidi += time_dilation_current
	sum_cpu += current_cpu
	if(time_dilation_current > peak_time_dilation)
		peak_time_dilation = time_dilation_current
		peak_time_dilation_worldtime = world.time
	if(current_cpu > peak_cpu)
		peak_cpu = current_cpu
		peak_cpu_worldtime = world.time
	if(current_maptick > peak_maptick)
		peak_maptick = current_maptick
	if(current_players > peak_players)
		peak_players = current_players

	SSblackbox.record_feedback("associative", "time_dilation_current", 1, list("[SQLtime()]" = list("current" = "[time_dilation_current]", "avg_fast" = "[time_dilation_avg_fast]", "avg" = "[time_dilation_avg]", "avg_slow" = "[time_dilation_avg_slow]")))
	log_perf(
		list(
			world.time,
			current_players,
			current_cpu,
			world.contents.len,
			time_dilation_current,
			time_dilation_avg_fast,
			time_dilation_avg,
			time_dilation_avg_slow,
			current_maptick,
			length(SStimer.timer_id_dict),
			SSmachines.cost,
			SSmobs.cost,
			SSlighting.cost,
			SSgarbage.cost,
			SStgui.cost,
			SStimer.cost,
			SSair.cost_turfs,
			SSair.turf_process_time(),
			SSair.cost_equalize,
			SSair.cost_post_process,
			SSair.cost_groups,
			SSair.cost_highpressure,
			SSair.cost_hotspots,
			SSair.cost_superconductivity,
			SSair.cost_pipenets,
			SSair.cost_rebuilds,
			SSair.get_amt_gas_mixes(),
			SSair.get_max_gas_mixes(),
			length(SSair.hotspots),
			length(SSair.networks),
			length(SSair.high_pressure_delta)
		)
	)

	// --- Spike detection FIRST (before expensive profile fetch) ---
	var/needs_spike_capture = FALSE
	var/spike_severity = 0
	if(!first_run && total_tidi_samples > 5)
		var/is_major_spike = (time_dilation_current > SPIKE_MAJOR_THRESHOLD) \
			&& (time_dilation_avg_slow > 0) \
			&& (time_dilation_current > time_dilation_avg_slow * SPIKE_MAJOR_MULTIPLIER)
		var/is_minor_spike = (time_dilation_current > SPIKE_MINOR_THRESHOLD) \
			&& (time_dilation_avg_slow > 0) \
			&& (time_dilation_current > time_dilation_avg_slow * SPIKE_MINOR_MULTIPLIER)

		if(is_major_spike && (world.time > last_major_spike_time + SPIKE_MAJOR_COOLDOWN))
			needs_spike_capture = TRUE
			spike_severity = SPIKE_SEVERITY_MAJOR
		else if(is_minor_spike && (world.time > last_spike_time + SPIKE_MINOR_COOLDOWN))
			needs_spike_capture = TRUE
			spike_severity = SPIKE_SEVERITY_MINOR

	// --- Profile data fetch: only when needed (spike or routine log every 30 cycles) ---
	var/list/parsed_profile = null
	var/routine_log_due = (times_fired % 30 == 0) // Every 30 cycles (~30 seconds) instead of every 10s
	if(SSprofiler.profiling_active && (needs_spike_capture || routine_log_due))
		parsed_profile = fetch_parsed_profile()

	// Log top 5 proc hotspots to perf log (only at routine interval)
	if(routine_log_due && length(parsed_profile))
		log_top_procs(parsed_profile)

	// Handle spike capture
	if(needs_spike_capture)
		if(!parsed_profile)
			parsed_profile = fetch_parsed_profile()
		if(spike_severity == SPIKE_SEVERITY_MAJOR)
			last_major_spike_time = world.time
		last_spike_time = world.time
		spike_count++
		capture_spike(spike_severity, parsed_profile)

/// Fetch and parse world.Profile() data via global cache. Returns list of valid assoc entries or null.
/datum/controller/subsystem/time_track/proc/fetch_parsed_profile()
	return SSprofiler.get_cached_profile()

/// Log top 5 procs by self time to perf CSV (existing behavior, refactored)
/datum/controller/subsystem/time_track/proc/log_top_procs(list/candidates)
	if(!length(candidates))
		return
	// Partial selection sort — top 5 only
	var/top_count = min(5, length(candidates))
	for(var/i in 1 to top_count)
		var/max_idx = i
		for(var/j in (i + 1) to length(candidates))
			if(candidates[j]["self"] > candidates[max_idx]["self"])
				max_idx = j
		if(max_idx != i)
			var/temp = candidates[i]
			candidates[i] = candidates[max_idx]
			candidates[max_idx] = temp

	var/list/parts = list("PROCS")
	for(var/i in 1 to top_count)
		var/list/e = candidates[i]
		parts += "[e["name"]]:[round(e["self"], 0.01)]:[e["calls"]]"
	log_perf(parts)

/// Capture a performance spike with detailed context
/datum/controller/subsystem/time_track/proc/capture_spike(severity, list/parsed_profile)
	var/severity_label = severity == SPIKE_SEVERITY_MAJOR ? "MAJOR" : "MINOR"

	var/list/lines = list()
	lines += "=== SPIKE [severity_label] [time2text(world.timeofday, "hh:mm:ss")] | world_time=[world.time] | tidi=[round(time_dilation_current, 0.1)]% (fast=[round(time_dilation_avg_fast, 0.1)]% avg=[round(time_dilation_avg, 0.1)]% slow=[round(time_dilation_avg_slow, 0.1)]%) | cpu=[world.cpu]% | players=[length(GLOB.clients)] ==="

	// Top 15 procs if profile data is available
	var/list/top_proc_strings = list()
	if(length(parsed_profile))
		// Partial selection sort — top 15
		var/top_count = min(15, length(parsed_profile))
		for(var/i in 1 to top_count)
			var/max_idx = i
			for(var/j in (i + 1) to length(parsed_profile))
				if(parsed_profile[j]["self"] > parsed_profile[max_idx]["self"])
					max_idx = j
			if(max_idx != i)
				var/temp = parsed_profile[i]
				parsed_profile[i] = parsed_profile[max_idx]
				parsed_profile[max_idx] = temp

		lines += "  -- Top 15 procs (self time) --"
		for(var/i in 1 to top_count)
			var/list/e = parsed_profile[i]
			var/self_ms = isnum(e["self"]) ? e["self"] : 0
			var/calls = isnum(e["calls"]) ? max(e["calls"], 1) : 1
			lines += "    [i]. [e["name"]] | self=[round(self_ms, 0.01)]ms | calls=[calls] | avg=[round(self_ms / calls, 0.001)]ms"
			top_proc_strings += "[e["name"]]:[round(e["self"], 0.01)]:[e["calls"]]"
	else
		lines += "  (profiling data unavailable)"

	// Top 10 subsystem costs
	if(Master)
		var/list/ss_costs = list()
		for(var/datum/controller/subsystem/SS as anything in Master.subsystems)
			if(SS.flags & SS_NO_FIRE)
				continue
			ss_costs += list(list("name" = SS.name, "cost" = SS.cost, "tick" = SS.tick_usage))
		var/ss_top = min(10, length(ss_costs))
		for(var/i in 1 to ss_top)
			var/max_idx = i
			for(var/j in (i + 1) to length(ss_costs))
				if(ss_costs[j]["cost"] > ss_costs[max_idx]["cost"])
					max_idx = j
			if(max_idx != i)
				var/temp = ss_costs[i]
				ss_costs[i] = ss_costs[max_idx]
				ss_costs[max_idx] = temp
		lines += "  -- Subsystem costs (top 10) --"
		for(var/i in 1 to ss_top)
			var/list/ss = ss_costs[i]
			lines += "    [i]. [ss["name"]] | cost=[round(ss["cost"], 0.01)]ms | tick=[round(ss["tick"], 0.01)]%"

	// Queue sizes
	lines += "  -- Queue sizes --"
	lines += "    SSmachines=[length(SSmachines.processing)] | SSmobs=[length(GLOB.mob_living_list)] | SSprocessing=[length(SSprocessing.processing)] | SSfastprocess=[length(SSfastprocess.processing)] | SSobj=[length(SSobj.processing)] | SStimer=[length(SStimer.timer_id_dict)]"
	lines += ""

	// Write to spike log
	if(GLOB.profiler_spike_log)
		WRITE_LOG_NO_FORMAT(GLOB.profiler_spike_log, jointext(lines, "\n"))

	// Track worst spike for round-end report
	if(time_dilation_current > worst_spike_tidi)
		worst_spike_tidi = time_dilation_current
		worst_spike_worldtime = world.time
		worst_spike_procs = top_proc_strings

	// Major spikes notify admins
	if(severity == SPIKE_SEVERITY_MAJOR)
		var/top_proc_name = length(parsed_profile) ? parsed_profile[1]["name"] : "N/A"
		var/top_proc_self = length(parsed_profile) ? "[round(parsed_profile[1]["self"], 0.01)]ms" : "N/A"
		message_admins("PERFORMANCE: Spike [severity_label] — tidi=[round(time_dilation_current, 0.1)]% (avg_slow=[round(time_dilation_avg_slow, 0.1)]%) | cpu=[world.cpu]% | top proc: [top_proc_name] ([top_proc_self]) — see auto_profiler_spikes.log")

/// Returns accumulated round statistics as an assoc list (for round-end report)
/datum/controller/subsystem/time_track/proc/get_accumulated_stats()
	return list(
		"peak_time_dilation" = peak_time_dilation,
		"peak_time_dilation_worldtime" = peak_time_dilation_worldtime,
		"avg_time_dilation" = total_tidi_samples > 0 ? round(sum_tidi / total_tidi_samples, 0.1) : 0,
		"peak_cpu" = peak_cpu,
		"peak_cpu_worldtime" = peak_cpu_worldtime,
		"avg_cpu" = total_tidi_samples > 0 ? round(sum_cpu / total_tidi_samples, 0.1) : 0,
		"peak_maptick" = peak_maptick,
		"peak_players" = peak_players,
		"tidi_samples" = total_tidi_samples,
		"spike_count" = spike_count,
		"worst_spike_tidi" = worst_spike_tidi,
		"worst_spike_worldtime" = worst_spike_worldtime,
		"worst_spike_procs" = worst_spike_procs,
		"time_dilation_current" = time_dilation_current,
		"time_dilation_avg_fast" = time_dilation_avg_fast,
		"time_dilation_avg" = time_dilation_avg,
		"time_dilation_avg_slow" = time_dilation_avg_slow,
	)
