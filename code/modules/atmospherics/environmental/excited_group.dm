// Excited Groups — LINDA-style idle detection for atmospheric processing
// Turfs that exchange gas are grouped together. When the group stabilizes
// (no significant exchange for N cycles), it breaks down (averages gas)
// then dismantles (removes turfs from active processing).
// This is the key optimization: only 100-2000 turfs are active, not 15-20k.

/datum/excited_group
	var/list/turf/open/turfs = list()
	var/breakdown_cooldown = 0
	var/dismantle_cooldown = 0

/datum/excited_group/Destroy()
	for(var/turf/open/T as anything in turfs)
		T.excited_group = null
	turfs.Cut()
	SSair.excited_groups -= src
	return ..()

/// Add a turf to this excited group
/datum/excited_group/proc/add_turf(turf/open/T)
	if(T.excited_group == src)
		return
	if(T.excited_group)
		// Turf already in another group — merge
		merge_with(T.excited_group)
		return
	if(turfs.len >= EXCITED_GROUP_MAX_SIZE)
		ATMOS_DEBUG_LOG("GROUP_FULL ([T.x],[T.y],[T.z]) cannot add, group size=[turfs.len] max=[EXCITED_GROUP_MAX_SIZE]")
		return
	turfs += T
	T.excited_group = src
	ATMOS_DEBUG_LOG("GROUP_ADD ([T.x],[T.y],[T.z]) group size=[turfs.len]")

/// Merge another excited group into this one
/// WARNING: This proc is inlined in turf_processing.dm process_cell() for performance.
/// Any changes here MUST be mirrored in the inline version!
/datum/excited_group/proc/merge_with(datum/excited_group/other)
	if(other == src)
		return
	if(turfs.len + other.turfs.len > EXCITED_GROUP_MAX_SIZE)
		ATMOS_DEBUG_LOG("GROUP_MERGE_BLOCKED size_a=[turfs.len] size_b=[other.turfs.len] max=[EXCITED_GROUP_MAX_SIZE]")
		return
	ATMOS_DEBUG_LOG("GROUP_MERGE size_a=[turfs.len] size_b=[other.turfs.len] result=[turfs.len + other.turfs.len]")
	for(var/turf/open/T as anything in other.turfs)
		T.excited_group = src
	turfs += other.turfs
	other.turfs.Cut()
	// Take the worse (higher) cooldowns to prevent premature breakdown
	breakdown_cooldown = max(breakdown_cooldown, other.breakdown_cooldown)
	dismantle_cooldown = max(dismantle_cooldown, other.dismantle_cooldown)
	SSair.excited_groups -= other
	// Don't qdel — just remove from list. Let GC handle it.

/// Called each SSair tick. Returns TRUE if the group should be dismantled.
/datum/excited_group/proc/process_group()
	breakdown_cooldown++
	dismantle_cooldown++
	ATMOS_DEBUG_LOG("GROUP_TICK size=[turfs.len] breakdown_cd=[breakdown_cooldown]/[EXCITED_GROUP_BREAKDOWN_CYCLES] dismantle_cd=[dismantle_cooldown]/[EXCITED_GROUP_DISMANTLE_CYCLES]")
	if(breakdown_cooldown >= EXCITED_GROUP_BREAKDOWN_CYCLES)
		breakdown_cooldown = 0
		ATMOS_DEBUG_LOG("GROUP_BREAKDOWN_START size=[turfs.len]")
		equalize()
#ifdef TESTING
		SSair.prof_groups_equalized++
#endif
	if(dismantle_cooldown >= EXCITED_GROUP_DISMANTLE_CYCLES)
		ATMOS_DEBUG_LOG("GROUP_DISMANTLE_START size=[turfs.len]")
		dismantle()
#ifdef TESTING
		SSair.prof_groups_dismantled++
#endif
		return TRUE
	return FALSE

/// Average all gas contents across member turfs (breakdown)
/datum/excited_group/proc/equalize()
	var/turf_count = turfs.len
	if(turf_count <= 1)
		return

	// Sum all gas and thermal energy
	var/list/total_core = NEW_CORE_MOLES
	var/list/total_rare = null
	var/total_thermal_energy = 0
	var/total_volume = 0

	// Pre-equalize logging
	if(GLOB.atmos_debug_logging)
		for(var/turf/open/dbg_T as anything in turfs)
			var/datum/gas_mixture/dbg_gm = dbg_T.air
			if(dbg_gm)
				log_game("ATMOS_DEBUG: GROUP_EQ_PRE ([dbg_T.x],[dbg_T.y],[dbg_T.z]) moles=[round(dbg_gm.total_moles(), 0.01)] temp=[round(dbg_gm.temperature, 0.01)] O2=[round(dbg_gm.core_moles[GAS_IDX_O2], 0.01)] N2=[round(dbg_gm.core_moles[GAS_IDX_N2], 0.01)]")

	for(var/turf/open/T as anything in turfs)
		var/datum/gas_mixture/gm = T.air
		if(!gm)
			continue
		var/list/cm = gm.core_moles
		total_core[1] += cm[1]
		total_core[2] += cm[2]
		total_core[3] += cm[3]
		total_core[4] += cm[4]
		total_core[5] += cm[5]
		total_core[6] += cm[6]
		total_core[7] += cm[7]
		total_core[8] += cm[8]
		total_core[9] += cm[9]
		total_core[10] += cm[10]
		total_thermal_energy += gm.thermal_energy()
		total_volume += gm.volume
		// Handle rare gases in separate associative list
		if(gm.rare_gases)
			if(!total_rare)
				total_rare = gm.rare_gases.Copy()
			else
				for(var/id as anything in gm.rare_gases)
					total_rare[id] += gm.rare_gases[id]

	if(total_volume <= 0)
		return

	// Distribute evenly by volume ratio
	for(var/turf/open/T as anything in turfs)
		var/datum/gas_mixture/gm = T.air
		if(!gm || gm._immutable)
			continue
		var/ratio = gm.volume / total_volume
		var/list/cm = gm.core_moles
		cm[1] = total_core[1] * ratio
		cm[2] = total_core[2] * ratio
		cm[3] = total_core[3] * ratio
		cm[4] = total_core[4] * ratio
		cm[5] = total_core[5] * ratio
		cm[6] = total_core[6] * ratio
		cm[7] = total_core[7] * ratio
		cm[8] = total_core[8] * ratio
		cm[9] = total_core[9] * ratio
		cm[10] = total_core[10] * ratio

		// Distribute rare gases to all turfs proportionally
		if(total_rare)
			if(!gm.rare_gases)
				gm.rare_gases = list()
			for(var/id as anything in total_rare)
				gm.rare_gases[id] = total_rare[id] * ratio
		else
			gm.rare_gases = null

		// Set temperature from thermal energy
		var/hc = gm.heat_capacity()
		if(hc > MINIMUM_HEAT_CAPACITY)
			gm.temperature = total_thermal_energy * ratio / hc
		else
			gm.temperature = TCMB
		UPDATE_SIMPLE_AIR(gm)

	// Post-equalize logging
	if(GLOB.atmos_debug_logging)
		for(var/turf/open/dbg_T as anything in turfs)
			var/datum/gas_mixture/dbg_gm = dbg_T.air
			if(dbg_gm)
				log_game("ATMOS_DEBUG: GROUP_EQ_POST ([dbg_T.x],[dbg_T.y],[dbg_T.z]) moles=[round(dbg_gm.total_moles(), 0.01)] temp=[round(dbg_gm.temperature, 0.01)] O2=[round(dbg_gm.core_moles[GAS_IDX_O2], 0.01)] N2=[round(dbg_gm.core_moles[GAS_IDX_N2], 0.01)]")

	// Reset cooldowns since we just equalized
	breakdown_cooldown = 0

/// Remove all turfs from active processing (dismantle)
/datum/excited_group/proc/dismantle()
	if(GLOB.atmos_debug_logging)
		for(var/turf/open/dbg_T as anything in turfs)
			var/datum/gas_mixture/dbg_gm = dbg_T.air
			log_game("ATMOS_DEBUG: GROUP_DISMANTLE_TURF ([dbg_T.x],[dbg_T.y],[dbg_T.z]) moles=[dbg_gm ? round(dbg_gm.total_moles(), 0.01) : "NULL"] temp=[dbg_gm ? round(dbg_gm.temperature, 0.01) : "NULL"]")
	for(var/turf/open/T as anything in turfs)
		T.excited = FALSE
		T.excited_group = null
		T.recently_active = 0
	SSair.active_turfs -= turfs
	turfs.Cut()
	SSair.excited_groups -= src
