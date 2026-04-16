// Pure DM turf atmosphere processing — replaces auxmos Rust FFI calls
// Called by SSair.fire() for active turf processing, excited groups, equalization, and finalization.

// ============================================================================
// Variable declarations
// ============================================================================

// SSair vars for tracking active turfs and excited groups.
// These were previously managed on the Rust side by auxmos.
/datum/controller/subsystem/air
	/// All turfs currently in active atmospheric processing
	var/list/turf/open/active_turfs = list()
	/// All currently active excited groups
	var/list/datum/excited_group/excited_groups = list()
	/// Turfs that had significant air exchange this tick and need reactions/visuals update
	var/list/turf/open/dirty_turfs = list()

// Turf vars for LINDA processing state.
// These were previously managed on the Rust side by auxmos.
/turf/open
	/// Whether this turf is in SSair.active_turfs
	var/excited = FALSE
	/// Which excited group this turf belongs to (null if none)
	var/datum/excited_group/excited_group = null
	/// Counter: how many ticks since last significant air exchange
	var/recently_active = 0
	/// Cooldown tracker for atmospheric processing
	var/atmos_cooldown = 0
	/// Whether this turf is in SSair.dirty_turfs (avoids O(n) |= check)
	var/tmp/dirty = FALSE

// ============================================================================
// SSair processing procs
// ============================================================================

/// Process all active turfs: archive air, then run process_cell() on each.
/// Replaces process_turfs_auxtools() Rust FFI call.
/datum/controller/subsystem/air/proc/process_turfs(resumed = FALSE)
	var/timer = TICK_USAGE_REAL
	if(!resumed)
		cached_cost = 0
		src.currentrun = active_turfs.Copy()
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/turf/open/T = currentrun[currentrun.len]
		currentrun.len--
		if(T)
			T.process_cell(times_fired)
		if(MC_TICK_CHECK)
			cached_cost += TICK_USAGE_REAL - timer
			return
	cached_cost += TICK_USAGE_REAL - timer
	cost_turfs = MC_AVERAGE(cost_turfs, TICK_DELTA_TO_MS(cached_cost))

/// Process all excited groups: tick cooldowns, breakdown, dismantle.
/// Replaces process_excited_groups_auxtools() Rust FFI call.
/datum/controller/subsystem/air/proc/process_excited_groups(resumed = FALSE)
	var/timer = TICK_USAGE_REAL
	if(!resumed)
		cached_cost = 0
		src.currentrun = excited_groups.Copy()
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/datum/excited_group/EG = currentrun[currentrun.len]
		currentrun.len--
		if(EG)
			EG.process_group()
		if(MC_TICK_CHECK)
			cached_cost += TICK_USAGE_REAL - timer
			return
	cached_cost += TICK_USAGE_REAL - timer
	cost_groups = MC_AVERAGE(cost_groups, TICK_DELTA_TO_MS(cached_cost))

/// BFS-based Monstermos-style equalization for explosive decompressions.
/// Only runs when equalize_enabled is TRUE.
/// Replaces process_turf_equalize_auxtools() Rust FFI call.
/datum/controller/subsystem/air/proc/process_turf_equalize(resumed = FALSE)
	var/timer = TICK_USAGE_REAL
	if(!resumed)
		cached_cost = 0
		src.currentrun = active_turfs.Copy()
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/turf/open/T = currentrun[currentrun.len]
		currentrun.len--
		if(!T || !T.air)
			continue
		T.equalize_pressure_in_zone(times_fired)
		if(MC_TICK_CHECK)
			cached_cost += TICK_USAGE_REAL - timer
			return
	cached_cost += TICK_USAGE_REAL - timer
	cost_equalize = MC_AVERAGE(cost_equalize, TICK_DELTA_TO_MS(cached_cost))

/// Finalize turf processing: run deferred reactions, update gas overlays,
/// and apply planetary atmosphere restoration.
/// Replaces finish_turf_processing_auxtools() Rust FFI call.
/datum/controller/subsystem/air/proc/finish_turf_processing(resumed = FALSE)
	var/timer = TICK_USAGE_REAL
	if(!resumed)
		cached_cost = 0
		src.currentrun = dirty_turfs.Copy()
		dirty_turfs.Cut()
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/turf/open/T = currentrun[currentrun.len]
		currentrun.len--
		if(!T)
			continue
		T.dirty = FALSE
#ifdef TESTING
		SSair.prof_dirty_turfs_processed++
#endif
		var/datum/gas_mixture/turf_air = T.air
		if(!turf_air)
			continue
		// Run reactions if air changed (skip for near-vacuum — no meaningful reactions)
		if(turf_air.total_moles() > MINIMUM_MOLE_COUNT)
#ifdef TESTING
			var/react_result = turf_air.react(T)
			if(react_result & REACTING)
				SSair.prof_finalize_reactions++
#else
			turf_air.react(T)
#endif
		// Update gas overlays
		T.update_visuals()
		// Planetary atmosphere restoration: slowly restore air toward initial mix
		if(T.planetary_atmos)
			var/datum/gas_mixture/planetary_mix = planetary[T.initial_gas_mix]
			if(planetary_mix)
				var/delta = planetary_mix.compare(turf_air)
				if(delta)
					ATMOS_DEBUG_LOG("PLANETARY_RESTORE ([T.x],[T.y],[T.z]) delta=[delta] moles_before=[round(turf_air.total_moles(), 0.01)] temp=[round(turf_air.temperature, 0.01)]")
					// Nudge air toward the planetary default (small ratio per tick)
					turf_air.merge(planetary_mix.remove_ratio(0.05))
		if(MC_TICK_CHECK)
			cached_cost += TICK_USAGE_REAL - timer
			return
	cached_cost += TICK_USAGE_REAL - timer
	cost_post_process = MC_AVERAGE(cost_post_process, TICK_DELTA_TO_MS(cached_cost))

/// Add a turf to the active processing list.
/datum/controller/subsystem/air/proc/add_to_active(turf/open/T)
	if(T.excited)
		return
	T.excited = TRUE
	active_turfs += T
	ATMOS_DEBUG_LOG("ACTIVATE ([T.x],[T.y],[T.z]) moles=[T.air ? round(T.air.total_moles(), 0.01) : "NULL"] temp=[T.air ? round(T.air.temperature, 0.01) : "NULL"] adj=[length(T.atmos_adjacent_turfs)]")
#ifdef TESTING
	prof_turfs_activated++
#endif

/// Remove a turf from the active processing list.
/datum/controller/subsystem/air/proc/remove_from_active(turf/open/T, reason = "unknown")
	ATMOS_DEBUG_LOG("DEACTIVATE ([T.x],[T.y],[T.z]) reason=[reason] moles=[T.air ? round(T.air.total_moles(), 0.01) : "NULL"] temp=[T.air ? round(T.air.temperature, 0.01) : "NULL"] recently_active=[T.recently_active] adj=[length(T.atmos_adjacent_turfs)] group=[T.excited_group ? "yes([T.excited_group.turfs.len])" : "no"]")
	T.excited = FALSE
	active_turfs -= T
#ifdef TESTING
	prof_turfs_deactivated++
#endif

// ============================================================================
// /turf/open processing procs
// ============================================================================

/// Core atmospheric processing for a single turf.
/// Shares air with adjacent turfs, manages excited groups, and tracks pressure differences.
/// All inner proc calls are inlined for maximum performance (~7000 calls/tick).
/turf/open/process_cell(fire_count)
	// Cache vars for performance
	var/datum/gas_mixture/our_air = air
	if(!our_air)
		return
	// Near-vacuum fast exit: nothing meaningful to share, let neighbors handle it
	if(our_air.total_moles() < 1)
		recently_active++
		ATMOS_DEBUG_LOG("VACUUM_FAST ([x],[y],[z]) moles=[round(our_air.total_moles(), 0.001)] temp=[round(our_air.temperature, 0.01)] recently_active=[recently_active] adj=[length(atmos_adjacent_turfs)]")
		if(recently_active >= 3)
			ATMOS_DEBUG_LOG("VACUUM_IDLE_OUT ([x],[y],[z]) removing from active after [recently_active] idle ticks, moles=[round(our_air.total_moles(), 0.001)]")
			SSair.remove_from_active(src, "vacuum_idle")
			if(excited_group)
				excited_group.turfs -= src
				if(!excited_group.turfs.len)
					SSair.excited_groups -= excited_group
				excited_group = null
		return

	our_air.archive()

	var/list/adjacent = atmos_adjacent_turfs
	if(!length(adjacent))
		return

	var/adjacent_count = length(adjacent)
	var/any_significant_share = FALSE

	for(var/turf/open/enemy in adjacent)
		var/datum/gas_mixture/enemy_air = enemy.air
		if(!enemy_air)
			continue

		// Archive neighbor air if it hasn't been archived this tick
		// (non-active turfs don't call process_cell(), so they need archiving here)
		if(!enemy.excited)
			enemy_air.archive()

		// Perform the air share calculation
		var/share_result = our_air.share(enemy_air, adjacent_count)

		// Check the result of the share — direct var access instead of get_last_share() proc call
		var/last_share = our_air.last_share
#ifdef TESTING
		SSair.prof_share_delta_sum += last_share
		if(last_share > SSair.prof_share_delta_max)
			SSair.prof_share_delta_max = last_share
#endif

		ATMOS_DEBUG_LOG("SHARE ([x],[y],[z])->([enemy.x],[enemy.y],[enemy.z]) last_share=[round(last_share, 0.001)] result=[round(share_result, 0.001)] our_moles=[round(our_air.total_moles(), 0.01)] enemy_moles=[round(enemy_air.total_moles(), 0.01)] our_temp=[round(our_air.temperature, 0.01)] enemy_temp=[round(enemy_air.temperature, 0.01)] immutable=[enemy_air._immutable]")

		if(last_share > MINIMUM_AIR_TO_SUSPEND)
			any_significant_share = TRUE

			// Don't add immutable-air turfs (space) to active processing or excited groups
			if(!enemy_air._immutable)
				// Inline: SSair.add_to_active(enemy) — avoids proc call overhead
				if(!enemy.excited)
					enemy.excited = TRUE
					SSair.active_turfs += enemy
					ATMOS_DEBUG_LOG("ACTIVATE_NEIGHBOR ([enemy.x],[enemy.y],[enemy.z]) activated by ([x],[y],[z]) last_share=[round(last_share, 0.001)] moles=[round(enemy_air.total_moles(), 0.01)]")

				// Inline: ensure_excited_group() + add_turf() — avoids 2 proc calls
				var/datum/excited_group/our_group = excited_group
				if(!our_group)
					our_group = new
					our_group.turfs += src
					excited_group = our_group
					SSair.excited_groups += our_group
#ifdef TESTING
					SSair.prof_groups_created++
#endif
				// Add enemy turf to our group (inline of add_turf)
				if(enemy.excited_group != our_group)
					if(enemy.excited_group)
						// Merge groups — INLINED from /datum/excited_group/proc/merge_with()
						// Keep in sync with excited_group.dm! Guard: checks enemy.excited_group != our_group
						// Size cap: only merge if combined size fits
						var/datum/excited_group/other = enemy.excited_group
						if(our_group.turfs.len + other.turfs.len <= EXCITED_GROUP_MAX_SIZE)
							for(var/turf/open/merge_turf as anything in other.turfs)
								merge_turf.excited_group = our_group
							our_group.turfs += other.turfs
							other.turfs.Cut()
							our_group.breakdown_cooldown = max(our_group.breakdown_cooldown, other.breakdown_cooldown)
							our_group.dismantle_cooldown = max(our_group.dismantle_cooldown, other.dismantle_cooldown)
							SSair.excited_groups -= other
#ifdef TESTING
							SSair.prof_groups_merged++
#endif
						// else: both groups stay separate — prevents mega-groups
					else if(our_group.turfs.len < EXCITED_GROUP_MAX_SIZE)
						our_group.turfs += enemy
						enemy.excited_group = our_group

				// Reset idle detection
				recently_active = 0
				enemy.recently_active = 0
			else
				// Immutable neighbor (space): keep self active but don't activate space
				recently_active = 0

		// Track pressure difference for spacewind
		if(share_result)
			var/abs_delta = abs(share_result)
			if(abs_delta > MINIMUM_MOLES_DELTA_TO_MOVE)
				if(share_result > 0)
					consider_pressure_difference(enemy, abs_delta)
				else
					enemy.consider_pressure_difference(src, abs_delta)
				// Trigger firelocks on large pressure differences (rapid decompression)
				// Only check if a firedoor exists nearby (bit 1 of adjacency value = firedoor present)
				if(abs_delta > ONE_ATMOSPHERE * 0.5 && (adjacent[enemy] & 2))
					consider_firelocks(enemy)

	// Per-turf idle detection — remove from active if no significant exchange
	if(!any_significant_share)
		recently_active++
		ATMOS_DEBUG_LOG("IDLE ([x],[y],[z]) recently_active=[recently_active] moles=[round(our_air.total_moles(), 0.01)] temp=[round(our_air.temperature, 0.01)] adj=[adjacent_count]")
		if(recently_active >= 3)
			ATMOS_DEBUG_LOG("IDLE_OUT ([x],[y],[z]) removing from active after [recently_active] idle ticks, moles=[round(our_air.total_moles(), 0.01)] temp=[round(our_air.temperature, 0.01)]")
			SSair.remove_from_active(src, "idle")
			if(excited_group)
				excited_group.turfs -= src
				if(!excited_group.turfs.len)
					SSair.excited_groups -= excited_group
				excited_group = null
			return
	else
		recently_active = 0
		// Flag-guarded dirty tracking: O(1) instead of O(n) list |= check
		if(!dirty)
			dirty = TRUE
			SSair.dirty_turfs += src

/// Ensure this turf is in an excited group. Creates one if needed.
/// Returns the excited group this turf belongs to.
/// Note: process_cell() inlines this for performance, but kept for external callers.
/turf/open/proc/ensure_excited_group()
	if(excited_group)
		return excited_group
	var/datum/excited_group/new_group = new
	new_group.add_turf(src)
	SSair.excited_groups += new_group
	return new_group

/// BFS equalization for explosive decompression scenarios.
/// Looks for large pressure differentials and moves gas in bulk toward low-pressure sinks.
/turf/open/equalize_pressure_in_zone(cyclenum)
	var/datum/gas_mixture/our_air = air
	if(!our_air)
		return

	var/our_pressure = our_air.return_pressure()

	var/list/adjacent = atmos_adjacent_turfs
	if(!length(adjacent))
		return

	// Find the largest pressure differential with an adjacent turf
	var/turf/open/best_target
	var/best_delta = 0

	for(var/turf/open/enemy in adjacent)
		var/datum/gas_mixture/enemy_air = enemy.air
		if(!enemy_air)
			continue
		var/enemy_pressure = enemy_air.return_pressure()
		var/delta = our_pressure - enemy_pressure
		if(abs(delta) > best_delta)
			best_delta = abs(delta)
			best_target = enemy

	// Only equalize if there's a massive pressure difference (> 1 atm)
	if(best_delta < ONE_ATMOSPHERE || !best_target)
		return

	// BFS flood-fill from this turf outward to find connected turfs and space tiles
	var/list/turf/open/flood_turfs = list(src)
	var/list/visited = list()
	visited[src] = TRUE
	var/list/turf/open/space_turfs = list()
	var/flood_index = 1
	var/hard_limit = SSair.equalize_hard_turf_limit

	while(flood_index <= flood_turfs.len && flood_turfs.len < hard_limit)
		var/turf/open/current = flood_turfs[flood_index]
		flood_index++

		var/list/current_adjacent = current.atmos_adjacent_turfs
		if(!length(current_adjacent))
			continue

		for(var/turf/open/neighbor in current_adjacent)
			if(visited[neighbor])
				continue
			visited[neighbor] = TRUE

			if(isspaceturf(neighbor))
				space_turfs += neighbor
				continue

			var/datum/gas_mixture/neighbor_air = neighbor.air
			if(!neighbor_air)
				continue

			flood_turfs += neighbor

	// If we found no space turfs, there's nowhere to decompress to
	if(!length(space_turfs))
		return

	// Calculate total moles in the flood zone
	var/total_moles = 0
	var/total_turfs = flood_turfs.len

	for(var/turf/open/T as anything in flood_turfs)
		var/datum/gas_mixture/T_air = T.air
		if(T_air)
			total_moles += T_air.total_moles()

	if(total_moles <= 0)
		return

	// Distribute the loss: target moles per turf after accounting for space sinks
	var/moles_per_turf = total_moles / (total_turfs + length(space_turfs))

	for(var/turf/open/T as anything in flood_turfs)
		var/datum/gas_mixture/T_air = T.air
		if(!T_air)
			continue
		var/current_moles = T_air.total_moles()
		var/delta_moles = current_moles - moles_per_turf
		if(delta_moles > MINIMUM_MOLES_DELTA_TO_MOVE)
			// Find nearest space turf for spacewind direction
			var/turf/open/nearest_space = space_turfs[1]
			var/nearest_dist = get_dist(T, nearest_space)
			if(length(space_turfs) > 1)
				for(var/turf/open/S as anything in space_turfs)
					var/check_dist = get_dist(T, S)
					if(check_dist < nearest_dist)
						nearest_dist = check_dist
						nearest_space = S
			// Apply spacewind and decompression effects
			T.consider_pressure_difference(nearest_space, delta_moles)
			T.consider_firelocks(nearest_space)
			T.handle_decompression_floor_rip(delta_moles)
			// Remove excess gas (vented to space)
			T_air.remove(delta_moles)

	SSair.num_equalize_processed += total_turfs
#ifdef TESTING
	SSair.prof_equalize_flood_total += total_turfs
	if(total_turfs > SSair.prof_equalize_flood_max)
		SSair.prof_equalize_flood_max = total_turfs
#endif
