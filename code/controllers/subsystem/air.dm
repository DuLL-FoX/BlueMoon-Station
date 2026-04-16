SUBSYSTEM_DEF(air)
	name = "Atmospherics"
	init_order = INIT_ORDER_AIR
	priority = FIRE_PRIORITY_AIR
	wait = 5
	flags = SS_BACKGROUND
	runlevels = RUNLEVEL_GAME | RUNLEVEL_POSTGAME

	var/cached_cost = 0

	var/cost_turfs = 0
	var/cost_groups = 0
	var/cost_highpressure = 0
	var/cost_hotspots = 0
	var/cost_post_process = 0
	var/cost_superconductivity = 0
	var/cost_pipenets = 0
	var/cost_rebuilds = 0
	var/cost_atmos_machinery = 0
	var/cost_equalize = 0
	var/low_pressure_turfs = 0
	var/high_pressure_turfs = 0

	var/num_group_turfs_processed = 0
	var/num_equalize_processed = 0

	var/list/hotspots = list()
	var/list/networks = list()
	/// Pipelines that need reconciliation this tick (update=TRUE)
	var/list/datum/pipeline/dirty_pipenets = list()
	var/list/pipenets_needing_rebuilt = list()
	var/list/obj/machinery/atmos_machinery = list()
	var/list/pipe_init_dirs_cache = list()

	//atmos singletons
	var/list/gas_reactions = list()
	var/list/atmos_gen
	var/list/planetary = list() //auxmos already caches static planetary mixes but could be convenient to do so here too
	//Special functions lists
	var/list/turf/open/high_pressure_delta = list()


	var/list/currentrun = list()
	var/currentpart = SSAIR_REBUILD_PIPENETS

	var/map_loading = TRUE

	var/log_explosive_decompression = TRUE // If things get spammy, admemes can turn this off.

	// Max number of turfs equalization will grab. (Scaled by atmos_speed_multiplier.)
	var/equalize_turf_limit = 10
	// Max number of turfs to look for a space turf, and max number of turfs that will be decompressed.
	var/equalize_hard_turf_limit = 2000
	// Whether equalization is enabled. Can be disabled for performance reasons.
	var/equalize_enabled = FALSE
	// Whether turf-to-turf heat exchanging should be enabled.
	var/heat_enabled = FALSE
	// Max number of times process_turfs will share in a tick. (Scaled by atmos_speed_multiplier.)
	var/share_max_steps = 3
	// Target for share_max_steps; can go below this, if it determines the thread is taking too long.
	var/share_max_steps_target = 3
	// Excited group processing will try to equalize groups with total pressure difference less than this amount.
	var/excited_group_pressure_goal = 1
	// Target for excited_group_pressure_goal; can go below this, if it determines the thread is taking too long.
	var/excited_group_pressure_goal_target = 1

#ifdef TESTING
	// ---- Atmos profiler counters (reset each log period) ----
	// Share call breakdown
	var/prof_share_calls = 0
	var/prof_share_simple = 0
	var/prof_share_isothermal = 0
	var/prof_share_thermal = 0
	var/prof_share_short_circuit = 0
	// Share delta magnitude tracking
	var/prof_share_delta_sum = 0
	var/prof_share_delta_max = 0
	// Archive call breakdown
	var/prof_archive_calls = 0
	var/prof_archive_simple = 0
	var/prof_archive_full = 0
	// Turf activation/deactivation
	var/prof_turfs_activated = 0
	var/prof_turfs_deactivated = 0
	var/prof_turfs_simple = 0
	var/prof_turfs_complex = 0
	// Excited group lifecycle
	var/prof_groups_created = 0
	var/prof_groups_merged = 0
	var/prof_groups_dismantled = 0
	var/prof_groups_equalized = 0
	// Excited group sizing (snapshot at log time)
	var/prof_eg_max_size = 0
	var/prof_eg_total_turfs = 0
	// Machinery & pipenets
	var/prof_machinery_processed = 0
	var/prof_pipenets_reconciled = 0
	var/prof_pipeline_reactions = 0
	var/prof_pipeline_react_skipped = 0
	// Dirty turfs & finalize reactions
	var/prof_dirty_turfs_processed = 0
	var/prof_finalize_reactions = 0
	// Equalization BFS stats
	var/prof_equalize_flood_total = 0
	var/prof_equalize_flood_max = 0
	// Reaction system
	var/prof_reactions_checked = 0
	var/prof_reactions_fired = 0
	var/prof_react_simple_skipped = 0
	// High pressure delta
	var/prof_high_pressure_count = 0
	// Per-fire raw timing (accumulated across fires in period, NOT smoothed)
	var/prof_raw_time_total = 0
	var/prof_raw_time_rebuild = 0
	var/prof_raw_time_pipenets = 0
	var/prof_raw_time_machinery = 0
	var/prof_raw_time_turfs = 0
	var/prof_raw_time_equalize = 0
	var/prof_raw_time_groups = 0
	var/prof_raw_time_finalize = 0
	var/prof_raw_time_highpressure = 0
	var/prof_raw_time_hotspots = 0
	var/prof_raw_time_conduction = 0
	// MC pause tracking
	var/prof_fire_pauses = 0
	var/prof_fires_completed = 0
	// Logging interval
	var/prof_log_interval = 10
	var/prof_log_countdown = 10
#endif

/datum/controller/subsystem/air/proc/apply_atmos_speed_multiplier()
	var/mult = CONFIG_GET(number/atmos_speed_multiplier)
	if(mult <= 1)
		return
	equalize_turf_limit = round(10 * mult)
	share_max_steps_target = round(3 * mult)
	share_max_steps = share_max_steps_target
	excited_group_pressure_goal_target = max(0.1, 1 / mult)
	excited_group_pressure_goal = excited_group_pressure_goal_target

/datum/controller/subsystem/air/stat_entry(msg)
	msg += "C:{HP:[round(cost_highpressure,1)]|HS:[round(cost_hotspots,1)]|SC:[round(cost_superconductivity,1)]|PN:[round(cost_pipenets,1)]|AM:[round(cost_atmos_machinery,1)]} TC:{AT:[round(cost_turfs,1)]|EG:[round(cost_groups,1)]|EQ:[round(cost_equalize,1)]|PO:[round(cost_post_process,1)]}|ACT:[active_turfs.len]|EG:[excited_groups.len]|HS:[hotspots.len]|PN:[networks.len]|HP:[high_pressure_delta.len]|POOL:[GLOB.gasmix_pool_count]"
	return ..()

/datum/controller/subsystem/air/Initialize(timeofday)
	map_loading = FALSE
	gasmix_pool_preallocate()
	setup_allturfs()
	setup_atmos_machinery()
	setup_pipenets()
	activate_nonequilibrium_turfs()
	gas_reactions = init_gas_reactions()
	equalize_enabled = CONFIG_GET(flag/atmos_equalize_enabled)
	apply_atmos_speed_multiplier()
#ifdef TESTING
	GLOB.atmos_profiler_log = "[GLOB.log_directory]/atmos-profiler-[GLOB.round_id ? GLOB.round_id : "NULL"]-[SSmapping.config?.map_name].csv"
	log_atmos_perf(list(
		"tick", "period", "fires_completed", "fire_pauses",
		"raw_total_ms", "raw_rebuild_ms", "raw_pipenets_ms", "raw_machinery_ms",
		"raw_turfs_ms", "raw_equalize_ms", "raw_groups_ms", "raw_finalize_ms",
		"raw_highpressure_ms", "raw_hotspots_ms", "raw_conduction_ms",
		"cost_turfs", "cost_groups", "cost_highpressure", "cost_hotspots",
		"cost_post_process", "cost_superconductivity", "cost_pipenets",
		"cost_rebuilds", "cost_atmos_machinery", "cost_equalize",
		"active_turfs", "turfs_activated", "turfs_deactivated",
		"turfs_simple", "turfs_complex",
		"share_total", "share_simple", "share_isothermal", "share_thermal", "share_short_circuit",
		"share_delta_avg", "share_delta_max",
		"archive_total", "archive_simple", "archive_full",
		"dirty_turfs_processed", "finalize_reactions",
		"eg_active", "eg_created", "eg_merged", "eg_equalized", "eg_dismantled",
		"eg_max_size", "eg_total_turfs",
		"pipenets_total", "pipenets_reconciled", "pipenets_dirty", "pipeline_reactions", "pipeline_react_skipped",
		"machinery_total", "machinery_processed",
		"pool_size", "pool_checkouts", "pool_returns", "pool_misses",
		"equalize_turfs_processed", "equalize_flood_total", "equalize_flood_max",
		"high_pressure_count", "low_pressure_turfs", "high_pressure_turfs",
		"reactions_checked", "reactions_fired", "react_simple_skipped",
		"hotspot_count"
	))
#endif
	return ..()


/datum/controller/subsystem/air/proc/add_reaction(datum/gas_reaction/r)
	gas_reactions += r
	sortTim(gas_reactions, GLOBAL_PROC_REF(cmp_gas_reaction))

/proc/reset_all_air()
	SSair.can_fire = 0
	message_admins("Air reset begun.")
	for(var/turf/open/T in world)
		T.Initalize_Atmos(0)
		CHECK_TICK
	message_admins("Air reset done.")
	SSair.can_fire = 1

/proc/fix_corrupted_atmos()

/datum/admins/proc/fixcorruption()
	set category = "Debug.3) Fixing"
	set desc="Fixes air that has weird NaNs (-1.#IND and such). Hopefully."
	set name="Fix Infinite Air"
	fix_corrupted_atmos()

/datum/admins/proc/toggle_atmos_debug_logging()
	set category = "Debug.3) Fixing"
	set desc="Toggle verbose atmos debug logging to game.log (ATMOS_DEBUG: prefix)"
	set name="Toggle Atmos Debug Logging"
	GLOB.atmos_debug_logging = !GLOB.atmos_debug_logging
	message_admins("[key_name_admin(usr)] toggled atmos debug logging [GLOB.atmos_debug_logging ? "ON" : "OFF"]")
	log_game("ATMOS_DEBUG: Logging [GLOB.atmos_debug_logging ? "ENABLED" : "DISABLED"] by [key_name(usr)]")

/datum/controller/subsystem/air/fire(resumed = 0)
	var/timer = TICK_USAGE_REAL
#ifdef TESTING
	var/prof_fire_start = TICK_USAGE_REAL
	if(resumed)
		prof_fire_pauses++
#endif

	if(!resumed)
		ATMOS_DEBUG_LOG("FIRE_START tick=[times_fired] active_turfs=[active_turfs.len] excited_groups=[excited_groups.len] dirty_turfs=[dirty_turfs.len] networks=[networks.len] hotspots=[hotspots.len] hp_delta=[high_pressure_delta.len]")

	// Adaptive throttling: reduce atmos processing intensity when server is lagging
	if(!resumed && SStime_track?.initialized)
		var/dilation = SStime_track.time_dilation_avg_fast
		if(dilation > 40)
			share_max_steps = 1
		else if(dilation > 20)
			share_max_steps = max(1, share_max_steps_target - 1)
		else
			share_max_steps = share_max_steps_target

	if(currentpart == SSAIR_REBUILD_PIPENETS)
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_rebuild_queue(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
#ifdef TESTING
			prof_raw_time_total += TICK_DELTA_TO_MS(TICK_USAGE_REAL - prof_fire_start)
#endif
			return
		cost_rebuilds = MC_AVERAGE(cost_rebuilds, TICK_DELTA_TO_MS(cached_cost))
#ifdef TESTING
		prof_raw_time_rebuild += TICK_DELTA_TO_MS(cached_cost)
#endif
		resumed = FALSE
		currentpart = SSAIR_PIPENETS

	if(currentpart == SSAIR_PIPENETS || !resumed)
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_pipenets(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
#ifdef TESTING
			prof_raw_time_total += TICK_DELTA_TO_MS(TICK_USAGE_REAL - prof_fire_start)
#endif
			return
		cost_pipenets = MC_AVERAGE(cost_pipenets, TICK_DELTA_TO_MS(cached_cost))
#ifdef TESTING
		prof_raw_time_pipenets += TICK_DELTA_TO_MS(cached_cost)
#endif
		resumed = 0
		currentpart = SSAIR_ATMOSMACHINERY

	if(currentpart == SSAIR_ATMOSMACHINERY)
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_atmos_machinery(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
#ifdef TESTING
			prof_raw_time_total += TICK_DELTA_TO_MS(TICK_USAGE_REAL - prof_fire_start)
#endif
			return
		resumed = 0
		cost_atmos_machinery = MC_AVERAGE(cost_atmos_machinery, TICK_DELTA_TO_MS(cached_cost))
#ifdef TESTING
		prof_raw_time_machinery += TICK_DELTA_TO_MS(cached_cost)
#endif
		currentpart = SSAIR_ACTIVETURFS

	if(currentpart == SSAIR_ACTIVETURFS)
		timer = TICK_USAGE_REAL
		process_turfs(resumed)
		if(state != SS_RUNNING)
#ifdef TESTING
			prof_raw_time_total += TICK_DELTA_TO_MS(TICK_USAGE_REAL - prof_fire_start)
#endif
			return
#ifdef TESTING
		// process_turfs sets cached_cost internally; capture raw timing from it
		prof_raw_time_turfs += TICK_DELTA_TO_MS(cached_cost)
#endif
		resumed = 0
		currentpart = equalize_enabled ? SSAIR_EQUALIZE : SSAIR_EXCITEDGROUPS

	if(currentpart == SSAIR_EQUALIZE)
		process_turf_equalize(resumed)
		if(state != SS_RUNNING)
#ifdef TESTING
			prof_raw_time_total += TICK_DELTA_TO_MS(TICK_USAGE_REAL - prof_fire_start)
#endif
			return
#ifdef TESTING
		prof_raw_time_equalize += TICK_DELTA_TO_MS(cached_cost)
#endif
		resumed = 0
		currentpart = SSAIR_EXCITEDGROUPS

	if(currentpart == SSAIR_EXCITEDGROUPS)
		process_excited_groups(resumed)
		if(state != SS_RUNNING)
#ifdef TESTING
			prof_raw_time_total += TICK_DELTA_TO_MS(TICK_USAGE_REAL - prof_fire_start)
#endif
			return
#ifdef TESTING
		prof_raw_time_groups += TICK_DELTA_TO_MS(cached_cost)
#endif
		resumed = 0
		currentpart = SSAIR_FINALIZE_TURFS

	if(currentpart == SSAIR_FINALIZE_TURFS)
		finish_turf_processing(resumed)
		if(state != SS_RUNNING)
#ifdef TESTING
			prof_raw_time_total += TICK_DELTA_TO_MS(TICK_USAGE_REAL - prof_fire_start)
#endif
			return
#ifdef TESTING
		prof_raw_time_finalize += TICK_DELTA_TO_MS(cached_cost)
#endif
		resumed = 0
		currentpart = SSAIR_HIGHPRESSURE

	if(currentpart == SSAIR_HIGHPRESSURE)
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_high_pressure_delta(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
#ifdef TESTING
			prof_raw_time_total += TICK_DELTA_TO_MS(TICK_USAGE_REAL - prof_fire_start)
#endif
			return
		cost_highpressure = MC_AVERAGE(cost_highpressure, TICK_DELTA_TO_MS(cached_cost))
#ifdef TESTING
		prof_raw_time_highpressure += TICK_DELTA_TO_MS(cached_cost)
#endif
		resumed = 0
		currentpart = SSAIR_HOTSPOTS

	if(currentpart == SSAIR_HOTSPOTS)
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_hotspots(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
#ifdef TESTING
			prof_raw_time_total += TICK_DELTA_TO_MS(TICK_USAGE_REAL - prof_fire_start)
#endif
			return
		cost_hotspots = MC_AVERAGE(cost_hotspots, TICK_DELTA_TO_MS(cached_cost))
#ifdef TESTING
		prof_raw_time_hotspots += TICK_DELTA_TO_MS(cached_cost)
#endif
		resumed = 0
		currentpart = heat_enabled ? SSAIR_TURF_CONDUCTION : SSAIR_REBUILD_PIPENETS

	// Heat -- slow and of questionable usefulness. Off by default for this reason. Pretty cool, though.
	if(currentpart == SSAIR_TURF_CONDUCTION)
		timer = TICK_USAGE_REAL
		if(process_turf_heat(TICK_REMAINING_MS))
			pause()
		var/conduction_cost = TICK_USAGE_REAL - timer
		cost_superconductivity = MC_AVERAGE(cost_superconductivity, TICK_DELTA_TO_MS(conduction_cost))
#ifdef TESTING
		prof_raw_time_conduction += TICK_DELTA_TO_MS(conduction_cost)
#endif
		if(state != SS_RUNNING)
#ifdef TESTING
			prof_raw_time_total += TICK_DELTA_TO_MS(TICK_USAGE_REAL - prof_fire_start)
#endif
			return
		resumed = 0
		currentpart = SSAIR_REBUILD_PIPENETS

#ifdef TESTING
	// Accumulate total fire time
	prof_raw_time_total += TICK_DELTA_TO_MS(TICK_USAGE_REAL - prof_fire_start)
	prof_fires_completed++
	// Profiler: log every N complete cycles
	prof_log_countdown--
	if(prof_log_countdown <= 0)
		atmos_profiler_log()
		atmos_profiler_reset()
		prof_log_countdown = prof_log_interval
#endif

/datum/controller/subsystem/air/proc/process_rebuild_queue(resumed = FALSE)
	if(!resumed)
		src.currentrun = pipenets_needing_rebuilt.Copy()
		pipenets_needing_rebuilt.Cut()
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/obj/machinery/atmospherics/AT = currentrun[currentrun.len]
		currentrun.len--
		if(!AT || QDELETED(AT))
			continue
		AT.rebuild_queued = FALSE
		AT.build_network()
		if(MC_TICK_CHECK)
			return

/datum/controller/subsystem/air/proc/process_pipenets(resumed = 0)
	if (!resumed)
		src.currentrun = dirty_pipenets.Copy()
		dirty_pipenets.Cut()
	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/datum/pipeline/P = currentrun[currentrun.len]
		currentrun.len--
		if(!P || QDELETED(P))
			continue
		P.in_dirty_list = FALSE
#ifdef TESTING
		prof_pipenets_reconciled++
#endif
		P.process()
		if(MC_TICK_CHECK)
			return

/datum/controller/subsystem/air/proc/add_to_rebuild_queue(obj/machinery/atmospherics/atmos_machine)
	if(atmos_machine.rebuild_queued)
		return
	atmos_machine.rebuild_queued = TRUE
	pipenets_needing_rebuilt += atmos_machine

/datum/controller/subsystem/air/proc/process_atmos_machinery(resumed = 0)
	var/seconds = wait * 0.1
	if (!resumed)
		src.currentrun = atmos_machinery.Copy()
	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/obj/machinery/M = currentrun[currentrun.len]
		currentrun.len--
		if(!M || (M.process_atmos(seconds) == PROCESS_KILL))
			atmos_machinery -= M
#ifdef TESTING
		prof_machinery_processed++
#endif
		if(MC_TICK_CHECK)
			return

/datum/controller/subsystem/air/proc/process_hotspots(resumed = 0)
	if (!resumed)
		src.currentrun = hotspots.Copy()
	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/obj/effect/hotspot/H = currentrun[currentrun.len]
		currentrun.len--
		if (H)
			H.process()
		else
			hotspots -= H
		if(MC_TICK_CHECK)
			return


/datum/controller/subsystem/air/proc/process_high_pressure_delta(resumed = 0)
	while (high_pressure_delta.len)
		var/turf/open/T = high_pressure_delta[high_pressure_delta.len]
		high_pressure_delta.len--
		if(!istype(T))
			continue
		T.high_pressure_movements()
		T.pressure_difference = 0
		T.pressure_specific_target = null
#ifdef TESTING
		prof_high_pressure_count++
#endif
		if(MC_TICK_CHECK)
			return

/// Heat conduction between turfs (walls heating rooms, space cooling, etc.)
/// TODO: Currently disabled — the old implementation was too expensive per-tick.
/// To re-enable: implement conduction using archived temperatures, process only
/// turfs with significant temperature deltas, and respect conductivity_blocked_directions.
/datum/controller/subsystem/air/proc/process_turf_heat(remaining)
	return FALSE

/datum/controller/subsystem/air/proc/heat_process_time()
	return 0

/datum/controller/subsystem/air/StartLoadingMap()
	map_loading = TRUE

/datum/controller/subsystem/air/StopLoadingMap()
	map_loading = FALSE

/datum/controller/subsystem/air/proc/setup_allturfs()
	var/list/turfs_to_init = block(locate(1, 1, 1), locate(world.maxx, world.maxy, world.maxz))
	var/times_fired = ++src.times_fired

	// Clear active turfs - faster than removing every single turf in the world
	// one-by-one, and Initalize_Atmos only ever adds `src` back in.

	for(var/thing as anything in turfs_to_init)
		var/turf/T = thing
		if (T.blocks_air)
			continue
		T.Initalize_Atmos(times_fired)
		CHECK_TICK

/datum/controller/subsystem/air/proc/setup_atmos_machinery()
	for (var/obj/machinery/atmospherics/AM in atmos_machinery)
		AM.atmosinit()
		CHECK_TICK

//this can't be done with setup_atmos_machinery() because
//	all atmos machinery has to initalize before the first
//	pipenet can be built.
/datum/controller/subsystem/air/proc/setup_pipenets()
	for (var/obj/machinery/atmospherics/AM in atmos_machinery)
		AM.build_network()
		CHECK_TICK

/datum/controller/subsystem/air/proc/activate_nonequilibrium_turfs()
	var/list/turfs_to_check = block(locate(1, 1, 1), locate(world.maxx, world.maxy, world.maxz))
	for(var/thing as anything in turfs_to_check)
		var/turf/open/T = thing
		if(!istype(T) || !T.air || T.blocks_air)
			continue
		// Space turfs use immutable air, don't process
		if(isspaceturf(T))
			continue
		var/list/adj = T.atmos_adjacent_turfs
		if(!length(adj))
			continue
		for(var/turf/open/neighbor in adj)
			if(!neighbor.air)
				continue
			if(isspaceturf(neighbor))
				// Adjacent to space — definitely needs processing
				add_to_active(T)
				break
			var/diff = T.air.compare(neighbor.air)
			if(diff)
				add_to_active(T)
				break
		CHECK_TICK

/datum/controller/subsystem/air/proc/setup_template_machinery(list/atmos_machines)
	if(!initialized) // yogs - fixes randomized bars
		return // yogs
	for(var/A as anything in atmos_machines)
		var/obj/machinery/atmospherics/AM = A
		AM.atmosinit()
		CHECK_TICK

	for(var/A as anything in atmos_machines)
		var/obj/machinery/atmospherics/AM = A
		AM.build_network()
		CHECK_TICK

/datum/controller/subsystem/air/proc/get_init_dirs(type, dir)
	if(!pipe_init_dirs_cache[type])
		pipe_init_dirs_cache[type] = list()

	if(!pipe_init_dirs_cache[type]["[dir]"])
		var/obj/machinery/atmospherics/temp = new type(null, FALSE, dir)
		pipe_init_dirs_cache[type]["[dir]"] = temp.GetInitDirections()
		qdel(temp)

	return pipe_init_dirs_cache[type]["[dir]"]

/datum/controller/subsystem/air/proc/generate_atmos()
	atmos_gen = list()
	for(var/T in subtypesof(/datum/atmosphere))
		var/datum/atmosphere/atmostype = T
		atmos_gen[initial(atmostype.id)] = new atmostype

/datum/controller/subsystem/air/proc/preprocess_gas_string(gas_string)
	if(!atmos_gen)
		generate_atmos()
	if(!atmos_gen[gas_string])
		return gas_string
	var/datum/atmosphere/mix = atmos_gen[gas_string]
	return mix.gas_string

/datum/controller/subsystem/air/proc/start_processing_machine(obj/machinery/machine)
	if(machine.atmos_processing)
		return
	machine.atmos_processing = TRUE
	atmos_machinery += machine

/datum/controller/subsystem/air/proc/stop_processing_machine(obj/machinery/machine)
	if(!machine.atmos_processing)
		return
	machine.atmos_processing = FALSE
	atmos_machinery -= machine
	currentrun -= machine

#ifdef TESTING
/datum/controller/subsystem/air/proc/atmos_profiler_log()
	// Snapshot excited group sizing
	prof_eg_total_turfs = 0
	prof_eg_max_size = 0
	for(var/datum/excited_group/eg as anything in excited_groups)
		var/sz = eg.turfs.len
		prof_eg_total_turfs += sz
		if(sz > prof_eg_max_size)
			prof_eg_max_size = sz

	// Snapshot simple_air distribution
	prof_turfs_simple = 0
	prof_turfs_complex = 0
	for(var/turf/open/T as anything in active_turfs)
		if(T?.air?.simple_air)
			prof_turfs_simple++
		else
			prof_turfs_complex++

	// Compute average share delta
	var/share_delta_avg = 0
	if(prof_share_calls > 0)
		share_delta_avg = prof_share_delta_sum / prof_share_calls

	// Write CSV row
	log_atmos_perf(list(
		times_fired, prof_log_interval, prof_fires_completed, prof_fire_pauses,
		round(prof_raw_time_total, 0.01), round(prof_raw_time_rebuild, 0.01),
		round(prof_raw_time_pipenets, 0.01), round(prof_raw_time_machinery, 0.01),
		round(prof_raw_time_turfs, 0.01), round(prof_raw_time_equalize, 0.01),
		round(prof_raw_time_groups, 0.01), round(prof_raw_time_finalize, 0.01),
		round(prof_raw_time_highpressure, 0.01), round(prof_raw_time_hotspots, 0.01),
		round(prof_raw_time_conduction, 0.01),
		round(cost_turfs, 0.1), round(cost_groups, 0.1),
		round(cost_highpressure, 0.1), round(cost_hotspots, 0.1),
		round(cost_post_process, 0.1), round(cost_superconductivity, 0.1),
		round(cost_pipenets, 0.1), round(cost_rebuilds, 0.1),
		round(cost_atmos_machinery, 0.1), round(cost_equalize, 0.1),
		active_turfs.len, prof_turfs_activated, prof_turfs_deactivated,
		prof_turfs_simple, prof_turfs_complex,
		prof_share_calls, prof_share_simple, prof_share_isothermal,
		prof_share_thermal, prof_share_short_circuit,
		round(share_delta_avg, 0.01), round(prof_share_delta_max, 0.01),
		prof_archive_calls, prof_archive_simple, prof_archive_full,
		prof_dirty_turfs_processed, prof_finalize_reactions,
		excited_groups.len, prof_groups_created, prof_groups_merged,
		prof_groups_equalized, prof_groups_dismantled,
		prof_eg_max_size, prof_eg_total_turfs,
		networks.len, prof_pipenets_reconciled, dirty_pipenets.len,
		prof_pipeline_reactions, prof_pipeline_react_skipped,
		atmos_machinery.len, prof_machinery_processed,
		GLOB.gasmix_pool_count, GLOB.gasmix_pool_checkouts,
		GLOB.gasmix_pool_returns, GLOB.gasmix_pool_misses,
		num_equalize_processed, prof_equalize_flood_total, prof_equalize_flood_max,
		prof_high_pressure_count, low_pressure_turfs, high_pressure_turfs,
		prof_reactions_checked, prof_reactions_fired, prof_react_simple_skipped,
		hotspots.len
	))

	// Secondary human-readable log
	log_game("ATMOS_PROFILER tick=[times_fired] period=[prof_log_interval] fires=[prof_fires_completed] pauses=[prof_fire_pauses]")
	log_game("ATMOS_PROFILER RAW_MS: total=[round(prof_raw_time_total,0.01)] rebuild=[round(prof_raw_time_rebuild,0.01)] pipe=[round(prof_raw_time_pipenets,0.01)] mach=[round(prof_raw_time_machinery,0.01)] turfs=[round(prof_raw_time_turfs,0.01)] eq=[round(prof_raw_time_equalize,0.01)] groups=[round(prof_raw_time_groups,0.01)] final=[round(prof_raw_time_finalize,0.01)] hp=[round(prof_raw_time_highpressure,0.01)] hs=[round(prof_raw_time_hotspots,0.01)] cond=[round(prof_raw_time_conduction,0.01)]")
	log_game("ATMOS_PROFILER COSTS: turfs=[round(cost_turfs,0.1)]ms mach=[round(cost_atmos_machinery,0.1)]ms pipe=[round(cost_pipenets,0.1)]ms hp=[round(cost_highpressure,0.1)]ms post=[round(cost_post_process,0.1)]ms groups=[round(cost_groups,0.1)]ms rebuilds=[round(cost_rebuilds,0.1)]ms")
	log_game("ATMOS_PROFILER SHARE: total=[prof_share_calls] simple=[prof_share_simple] iso=[prof_share_isothermal] thermal=[prof_share_thermal] short_circuit=[prof_share_short_circuit] delta_avg=[round(share_delta_avg,0.01)] delta_max=[round(prof_share_delta_max,0.01)]")
	log_game("ATMOS_PROFILER ARCHIVE: total=[prof_archive_calls] simple=[prof_archive_simple] full=[prof_archive_full]")
	log_game("ATMOS_PROFILER TURFS: active=[active_turfs.len] activated=[prof_turfs_activated] deactivated=[prof_turfs_deactivated] simple_air=[prof_turfs_simple] complex=[prof_turfs_complex] dirty=[prof_dirty_turfs_processed] reactions=[prof_finalize_reactions]")
	log_game("ATMOS_PROFILER GROUPS: active=[excited_groups.len] created=[prof_groups_created] merged=[prof_groups_merged] equalized=[prof_groups_equalized] dismantled=[prof_groups_dismantled] max_size=[prof_eg_max_size] total_turfs=[prof_eg_total_turfs]")
	log_game("ATMOS_PROFILER MACHINERY: total=[atmos_machinery.len] processed=[prof_machinery_processed]")
	log_game("ATMOS_PROFILER PIPENETS: total=[networks.len] reconciled=[prof_pipenets_reconciled] dirty=[dirty_pipenets.len] reactions=[prof_pipeline_reactions] react_skipped=[prof_pipeline_react_skipped]")
	log_game("ATMOS_PROFILER POOL: size=[GLOB.gasmix_pool_count] checkouts=[GLOB.gasmix_pool_checkouts] returns=[GLOB.gasmix_pool_returns] misses=[GLOB.gasmix_pool_misses]")
	log_game("ATMOS_PROFILER EQUALIZE: turfs=[num_equalize_processed] flood_total=[prof_equalize_flood_total] flood_max=[prof_equalize_flood_max]")
	log_game("ATMOS_PROFILER PRESSURE: hp_count=[prof_high_pressure_count] low=[low_pressure_turfs] high=[high_pressure_turfs]")
	log_game("ATMOS_PROFILER REACTIONS: checked=[prof_reactions_checked] fired=[prof_reactions_fired] simple_skipped=[prof_react_simple_skipped] hotspots=[hotspots.len]")

/datum/controller/subsystem/air/proc/atmos_profiler_reset()
	// Share counters
	prof_share_calls = 0
	prof_share_simple = 0
	prof_share_isothermal = 0
	prof_share_thermal = 0
	prof_share_short_circuit = 0
	prof_share_delta_sum = 0
	prof_share_delta_max = 0
	// Archive counters
	prof_archive_calls = 0
	prof_archive_simple = 0
	prof_archive_full = 0
	// Turf counters
	prof_turfs_activated = 0
	prof_turfs_deactivated = 0
	prof_turfs_simple = 0
	prof_turfs_complex = 0
	// Group counters
	prof_groups_created = 0
	prof_groups_merged = 0
	prof_groups_dismantled = 0
	prof_groups_equalized = 0
	prof_eg_max_size = 0
	prof_eg_total_turfs = 0
	// Machinery & pipenets
	prof_machinery_processed = 0
	prof_pipenets_reconciled = 0
	prof_pipeline_reactions = 0
	prof_pipeline_react_skipped = 0
	// Dirty turfs & reactions
	prof_dirty_turfs_processed = 0
	prof_finalize_reactions = 0
	// Equalization
	prof_equalize_flood_total = 0
	prof_equalize_flood_max = 0
	num_equalize_processed = 0
	// Reaction system
	prof_reactions_checked = 0
	prof_reactions_fired = 0
	prof_react_simple_skipped = 0
	// High pressure
	prof_high_pressure_count = 0
	// Raw timing
	prof_raw_time_total = 0
	prof_raw_time_rebuild = 0
	prof_raw_time_pipenets = 0
	prof_raw_time_machinery = 0
	prof_raw_time_turfs = 0
	prof_raw_time_equalize = 0
	prof_raw_time_groups = 0
	prof_raw_time_finalize = 0
	prof_raw_time_highpressure = 0
	prof_raw_time_hotspots = 0
	prof_raw_time_conduction = 0
	// MC pause tracking
	prof_fire_pauses = 0
	prof_fires_completed = 0
	// Pool stats (reset for per-period deltas)
	GLOB.gasmix_pool_checkouts = 0
	GLOB.gasmix_pool_returns = 0
	GLOB.gasmix_pool_misses = 0
#endif

#undef SSAIR_PIPENETS
#undef SSAIR_ATMOSMACHINERY
#undef SSAIR_EXCITEDGROUPS
#undef SSAIR_HIGHPRESSURE
#undef SSAIR_HOTSPOTS
#undef SSAIR_TURF_CONDUCTION
#undef SSAIR_REBUILD_PIPENETS
#undef SSAIR_EQUALIZE
#undef SSAIR_ACTIVETURFS
#undef SSAIR_TURF_POST_PROCESS
#undef SSAIR_FINALIZE_TURFS
#undef SSAIR_ATMOSMACHINERY_AIR
