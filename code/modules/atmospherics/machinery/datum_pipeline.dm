/datum/pipeline
	var/datum/gas_mixture/air
	var/list/datum/gas_mixture/other_airs

	var/list/obj/machinery/atmospherics/pipe/members
	var/list/obj/machinery/atmospherics/components/other_atmosmch

	var/update = TRUE
	/// Whether this pipeline is in SSair.dirty_pipenets (prevents duplicate adds)
	var/tmp/in_dirty_list = FALSE
	/// Cached result of get_all_connected_airs() — invalidated when update=TRUE
	var/list/datum/gas_mixture/cached_connected_airs

/datum/pipeline/New()
	other_airs = list()
	members = list()
	other_atmosmch = list()
	SSair.networks += src
	// New pipelines start dirty (update=TRUE), add to dirty queue
	if(!in_dirty_list)
		in_dirty_list = TRUE
		SSair.dirty_pipenets += src

/// Mark this pipeline as needing reconciliation next tick.
/datum/pipeline/proc/mark_dirty()
	update = TRUE
	cached_connected_airs = null
	if(!in_dirty_list)
		in_dirty_list = TRUE
		SSair.dirty_pipenets += src

/datum/pipeline/Destroy()
	SSair.networks -= src
	SSair.currentrun -= src
	if(in_dirty_list)
		SSair.dirty_pipenets -= src
		in_dirty_list = FALSE
	if(air?.return_volume())  //	BLUEMOON EDIT: TODO:runtime
		temporarily_store_air()
	for(var/obj/machinery/atmospherics/pipe/P as anything in members)
		P.parent = null
	for(var/obj/machinery/atmospherics/components/C as anything in other_atmosmch)
		if(!C.parents)
			continue
		for(var/i in 1 to length(C.parents))
			if(C.parents[i] == src)
				C.parents[i] = null
	members.Cut()
	other_atmosmch.Cut()
	for(var/datum/gas_mixture/gm as anything in other_airs)
		if(gm._owner_pipeline == src)
			gm._owner_pipeline = null
	other_airs.Cut()
	cached_connected_airs = null
	gasmix_release(air)
	air = null
	return ..()

/datum/pipeline/process()
	if(!update)
		return
	update = FALSE
	reconcile_air()
	if(air)
		// No reaction can fire with only O2+N2 — skip the full reaction loop
		if(air.simple_air)
#ifdef TESTING
			SSair.prof_pipeline_react_skipped++
#endif
			return
		var/react_result = air.react(src)
		if(react_result & REACTING)
			mark_dirty() // reaction ongoing, need to reprocess
#ifdef TESTING
			SSair.prof_pipeline_reactions++
#endif

/datum/pipeline/proc/build_pipeline(obj/machinery/atmospherics/base)
	if(QDELETED(base))
		stack_trace("build_pipeline() called with QDELETED base [base?.type] at [base ? COORD(base) : "null"]")
		return
	var/volume = 0
	if(istype(base, /obj/machinery/atmospherics/pipe))
		var/obj/machinery/atmospherics/pipe/E = base
		volume = E.volume
		members += E
		if(E.air_temporary)
			air = E.air_temporary
			E.air_temporary = null
	else
		addMachineryMember(base)
	if(!air)
		air = gasmix_acquire()
	var/list/possible_expansions = list(base)
	while(possible_expansions.len > 0)
		// Don't use for-in here - modifying list during iteration causes illegal operation crashes
		var/obj/machinery/atmospherics/borderline = possible_expansions[1]
		possible_expansions -= borderline

		var/list/result = borderline.pipeline_expansion(src)

		if(result.len > 0)
			for(var/obj/machinery/atmospherics/P in result)
				if(istype(P, /obj/machinery/atmospherics/pipe))
					var/obj/machinery/atmospherics/pipe/item = P
					if(!members.Find(item))

						if(item.parent && item.parent != src)
							// Clean up stale reference in old pipeline before reassigning
							var/datum/pipeline/old_parent = item.parent
							old_parent.members -= item
							if(!length(old_parent.members) && !length(old_parent.other_atmosmch))
								qdel(old_parent)
						members += item
						possible_expansions += item

						volume += item.volume
						item.parent = src

						if(item.air_temporary)
							air.merge(item.air_temporary)
							gasmix_release(item.air_temporary)
							item.air_temporary = null
				else
					steal_component_from_old_pipenet(P, borderline)
					P.setPipenet(src, borderline)
					addMachineryMember(P)

	air.set_volume(volume)

/**
 *  For a machine to properly "connect" to a pipeline and share gases,
 *  the pipeline needs to acknowledge a gas mixture as its member.
 *  This is currently handled by the other_airs list in the pipeline datum.
 *
 *	Other_airs itself is populated by gas mixtures through the parents list that each machineries have.
 *	This parents list is populated when a machinery calls update_parents and is then added into the queue by the controller.
 */
/// Clean up old pipeline references before reassigning a component to this pipeline.
/// Mirrors the pipe-stealing cleanup in build_pipeline for pipes.
/datum/pipeline/proc/steal_component_from_old_pipenet(obj/machinery/atmospherics/components/comp, obj/machinery/atmospherics/borderline)
	var/idx = comp.nodes.Find(borderline)
	if(!idx)
		return
	var/datum/pipeline/old_pipenet = comp.parents[idx]
	if(!old_pipenet || old_pipenet == src)
		return
	// Remove only the specific port's air from old pipeline
	var/datum/gas_mixture/old_air = comp.airs[idx]
	if(old_air)
		old_pipenet.other_airs -= old_air
		old_pipenet.cached_connected_airs = null
		if(old_air._owner_pipeline == old_pipenet)
			old_air._owner_pipeline = null
	// Only remove component from other_atmosmch if no other ports still reference old pipeline
	var/still_connected = FALSE
	for(var/j in 1 to comp.parents.len)
		if(j != idx && comp.parents[j] == old_pipenet)
			still_connected = TRUE
			break
	if(!still_connected)
		old_pipenet.other_atmosmch -= comp
	// Qdel orphaned pipeline (same pattern as pipe stealing)
	if(!length(old_pipenet.members) && !length(old_pipenet.other_atmosmch))
		qdel(old_pipenet)

/datum/pipeline/proc/addMachineryMember(obj/machinery/atmospherics/components/C)
	other_atmosmch |= C
	var/list/returned_airs = C.returnPipenetAirs(src)
	if (!length(returned_airs) || (null in returned_airs))
		stack_trace("addMachineryMember: Nonexistent (empty list) or null machinery gasmix added to pipeline datum from [C] \
		which is of type [C.type]. Nearby: ([C.x], [C.y], [C.z])")
		listclearnulls(returned_airs)
	for(var/datum/gas_mixture/gm as anything in returned_airs)
		if(gm._owner_pipeline && gm._owner_pipeline != src && !QDELETED(gm._owner_pipeline))
			stack_trace("addMachineryMember: air [REF(gm)] already owned by pipeline [gm._owner_pipeline]([REF(gm._owner_pipeline)]), stealing to [src]([REF(src)]). \
				Component [C.type] at [C.x],[C.y],[C.z]")
			gm._owner_pipeline.cached_connected_airs = null
			gm._owner_pipeline.other_airs -= gm
		gm._owner_pipeline = src
	other_airs |= returned_airs

/datum/pipeline/proc/addMember(obj/machinery/atmospherics/A, obj/machinery/atmospherics/N)
	if(istype(A, /obj/machinery/atmospherics/pipe))
		var/obj/machinery/atmospherics/pipe/P = A
		if(P.parent)
			merge(P.parent)
		P.parent = src
		var/list/adjacent = P.pipeline_expansion()
		for(var/obj/machinery/atmospherics/pipe/I in adjacent)
			if(I.parent == src)
				continue
			var/datum/pipeline/E = I.parent
			if(E)
				merge(E)
		if(!members.Find(P))
			members += P
			air.set_volume(air.return_volume() + P.volume)
	else
		steal_component_from_old_pipenet(A, N)
		A.setPipenet(src, N)
		addMachineryMember(A)

/datum/pipeline/proc/merge(datum/pipeline/E)
	if(E == src)
		return
	air.set_volume(air.return_volume() + E.air.return_volume())
	members.Add(E.members)
	for(var/obj/machinery/atmospherics/pipe/S as anything in E.members)
		S.parent = src
	air.merge(E.air)
	for(var/obj/machinery/atmospherics/components/C as anything in E.other_atmosmch)
		C.replacePipenet(E, src)
	other_atmosmch |= E.other_atmosmch
	if(null in E.other_airs)
		stack_trace("merge(): Pipeline [E]([REF(E)]) contains null gas mixtures in other_airs. Cleaning before merge.")
		listclearnulls(E.other_airs)
	for(var/datum/gas_mixture/gm as anything in E.other_airs)
		if(gm._owner_pipeline == E)
			gm._owner_pipeline = src
	other_airs |= E.other_airs
	E.members.Cut()
	E.other_atmosmch.Cut()
	E.other_airs.Cut()
	mark_dirty()
	qdel(E)

/obj/machinery/atmospherics/proc/addMember(obj/machinery/atmospherics/A)
	return

/obj/machinery/atmospherics/pipe/addMember(obj/machinery/atmospherics/A)
	if(!parent)
		return
	parent.addMember(A, src)

/obj/machinery/atmospherics/components/addMember(obj/machinery/atmospherics/A)
	var/datum/pipeline/P = returnPipenet(A)
	if(!P)
		CRASH("null.addMember() called by [type] on [COORD(src)]")
	P.addMember(A, src)


/datum/pipeline/proc/temporarily_store_air()
	//Update individual gas_mixtures by volume ratio
	var/air_vol = air.return_volume()
	if(air_vol <= 0)
		return

	for(var/obj/machinery/atmospherics/pipe/member as anything in members)
		member.air_temporary = gasmix_acquire(member.volume)
		member.air_temporary.copy_from(air)

		member.air_temporary.multiply(member.volume/air_vol)

		member.air_temporary.set_temperature(air.return_temperature())

/datum/pipeline/proc/temperature_interact(turf/target, share_volume, thermal_conductivity)
	var/total_heat_capacity = air.heat_capacity()
	var/partial_heat_capacity = total_heat_capacity*(share_volume/air.return_volume())
	var/target_temperature
	var/target_heat_capacity

	if(isopenturf(target))

		var/turf/open/modeled_location = target
		target_temperature = modeled_location.GetTemperature()
		target_heat_capacity = modeled_location.GetHeatCapacity()

		if(modeled_location.blocks_air)

			if((modeled_location.heat_capacity>0) && (partial_heat_capacity>0))
				var/delta_temperature = air.return_temperature() - target_temperature

				var/heat = thermal_conductivity*delta_temperature* \
					(partial_heat_capacity*target_heat_capacity/(partial_heat_capacity+target_heat_capacity))

				air.set_temperature(air.return_temperature() - heat/total_heat_capacity)
				modeled_location.TakeTemperature(heat/target_heat_capacity)

		else
			var/delta_temperature = 0
			var/sharer_heat_capacity = 0

			delta_temperature = (air.return_temperature() - target_temperature)
			sharer_heat_capacity = target_heat_capacity

			var/self_temperature_delta = 0
			var/sharer_temperature_delta = 0

			if((sharer_heat_capacity>0) && (partial_heat_capacity>0))
				var/heat = thermal_conductivity*delta_temperature* \
					(partial_heat_capacity*sharer_heat_capacity/(partial_heat_capacity+sharer_heat_capacity))

				self_temperature_delta = -heat/total_heat_capacity
				sharer_temperature_delta = heat/sharer_heat_capacity
			else
				return TRUE

			air.set_temperature(air.return_temperature() + self_temperature_delta)
			modeled_location.TakeTemperature(sharer_temperature_delta)


	else
		if((target.heat_capacity>0) && (partial_heat_capacity>0))
			var/delta_temperature = air.return_temperature() - target.return_temperature()

			var/heat = thermal_conductivity*delta_temperature* \
				(partial_heat_capacity*target.heat_capacity/(partial_heat_capacity+target.heat_capacity))

			air.set_temperature(air.return_temperature() - heat/total_heat_capacity)
	mark_dirty()

/datum/pipeline/proc/return_air()
	. = other_airs.Copy()
	if(air)
		. += air
	if(null in .)
		listclearnulls(.)
		stack_trace("[src]([REF(src)]) has one or more null gas mixtures, which may cause bugs. Null mixtures will not be considered in reconcile_air().")

/datum/pipeline/proc/empty()
	for(var/datum/gas_mixture/GM in get_all_connected_airs())
		GM.clear()

/datum/pipeline/proc/get_all_connected_airs()
	var/list/datum/gas_mixture/GL = list()
	var/list/datum/pipeline/PL = list()
	PL += src

	for(var/i = 1; i <= PL.len; i++) //can't do a for-each here because we may add to the list within the loop
		var/datum/pipeline/P = PL[i]
		if(!P)
			continue
		if(length(P.other_airs))
			GL += P.other_airs
		if(P.air)
			GL += P.air
		for(var/obj/machinery/atmospherics/components/atmosmch as anything in P.other_atmosmch)
			if (istype(atmosmch, /obj/machinery/atmospherics/components/binary/valve))
				var/obj/machinery/atmospherics/components/binary/valve/V = atmosmch
				if(V.on)
					PL |= V.parents[1]
					PL |= V.parents[2]
			else if (istype(atmosmch,/obj/machinery/atmospherics/components/binary/relief_valve))
				var/obj/machinery/atmospherics/components/binary/relief_valve/V = atmosmch
				if(V.opened)
					PL |= V.parents[1]
					PL |= V.parents[2]
			else if (istype(atmosmch, /obj/machinery/atmospherics/components/unary/portables_connector))
				var/obj/machinery/atmospherics/components/unary/portables_connector/C = atmosmch
				if(C.connected_device)
					GL += C.portableConnectorReturnAir()
	return GL

/datum/pipeline/proc/reconcile_air()
	var/list/datum/gas_mixture/GL = get_all_connected_airs()
	if(null in GL)
		listclearnulls(GL)
	cached_connected_airs = GL
	// Snapshot pipeline air before equalization
	var/pre_moles = air ? air.total_moles() : 0
	var/pre_temp = air ? air.temperature : 0
	equalize_all_gases_in_list(GL)
	// Only wake connected machinery if pipeline air actually changed
	if(air)
		var/moles_delta = abs(air.total_moles() - pre_moles)
		var/temp_delta = abs(air.temperature - pre_temp)
		if(moles_delta > MINIMUM_MOLES_DELTA_TO_MOVE || temp_delta > MINIMUM_TEMPERATURE_DELTA_TO_SUSPEND)
			for(var/obj/machinery/atmospherics/components/C as anything in other_atmosmch)
				C.wake_atmos()
