/*
What are the archived variables for?
	Calculations are done using the archived variables with the results merged into the regular variables.
	This prevents race conditions that arise based on the order of tile processing.
*/
/datum/gas_mixture
	/// Never ever set this variable, hooked into vv_get_var for view variables viewing.
	var/gas_list_view_only
	var/initial_volume = CELL_VOLUME //liters

	var/list/reaction_results
	var/list/analyzer_results //used for analyzer feedback - not initialized until its used

	// ---- Core gas storage ----
	/// Flat list of length CORE_GAS_COUNT, one slot per core gas. Access: core_moles[GAS_IDX_O2] etc.
	var/list/core_moles
	/// Archived snapshot of core_moles for share() calculations. Pre-allocated once.
	var/list/archived_core_moles
	/// LAZY associative list for non-core gases. Key = gas string ID, value = moles. null when empty.
	var/list/rare_gases

	/// Temperature in kelvins
	var/temperature = TCMB
	/// Archived temperature for share() calculations
	var/tmp/temperature_archived = TCMB

	/// Volume in liters
	var/volume = CELL_VOLUME
	/// Last share delta (abs moles moved)
	var/tmp/last_share = 0

	/// Minimum heat capacity (used for vacuum hack)
	var/tmp/min_heat_capacity = 0

	// ---- Pool flags ----
	/// Pipeline that has this air in its other_airs. Used for O(1) cleanup instead of scanning all pipelines.
	var/tmp/datum/pipeline/_owner_pipeline
	/// TRUE when this mixture is currently in the object pool
	var/tmp/_pooled = FALSE
	/// TRUE for immutable mixtures (space, closed turfs)
	var/tmp/_immutable = FALSE
	/// TRUE to bypass pool intercept in Destroy()
	var/tmp/_force_destroy = FALSE
	/// TRUE when only O2+N2 present (gases 3-10 all zero, no rare_gases). Enables fast paths in share()/archive().
	var/tmp/simple_air = TRUE

/datum/gas_mixture/New(vol)
	if(!isnull(vol))
		initial_volume = vol
		volume = vol
	else
		volume = initial_volume
	// Ensure gas index tables are initialized (triggers GLOB.gas_data lazy init)
	if(!length(GLOB.gas_idx_to_specific_heat))
		init_gas_index_tables()
	core_moles = NEW_CORE_MOLES
	archived_core_moles = NEW_CORE_MOLES
	reaction_results = list()

/datum/gas_mixture/Destroy()
	// Safety net: clean up pipeline references before any return path
	if(_owner_pipeline && !QDELETED(_owner_pipeline))
		_owner_pipeline.cached_connected_airs = null
		_owner_pipeline.other_airs -= src
		_owner_pipeline = null
	// If force destroy, skip pool logic
	if(_force_destroy)
		reaction_results = null
		analyzer_results = null
		core_moles = null
		archived_core_moles = null
		rare_gases = null
		return ..()
	// If immutable, destroy normally
	if(_immutable)
		reaction_results = null
		analyzer_results = null
		core_moles = null
		archived_core_moles = null
		rare_gases = null
		return ..()
	// If already in pool, remove from pool before destroying
	if(_pooled)
		GLOB.gasmix_pool -= src
		GLOB.gasmix_pool_count--
		_pooled = FALSE
		stack_trace("qdel() called on a gas_mixture that was already in the pool")
	// Attempt to return to pool
	if(GLOB.gasmix_pool_count < GASMIX_POOL_MAX)
		_pool_reset()
		_pooled = TRUE
		GLOB.gasmix_pool_count++
		GLOB.gasmix_pool += src
		GLOB.gasmix_pool_returns++
		return QDEL_HINT_LETMELIVE
	// Pool full or already pooled — actually destroy
	reaction_results = null
	analyzer_results = null
	core_moles = null
	archived_core_moles = null
	rare_gases = null
	return ..()

/// Zero all fields for pool recycling
/datum/gas_mixture/proc/_pool_reset()
	var/list/cm = core_moles
	if(!cm)
		core_moles = NEW_CORE_MOLES
		cm = core_moles
	cm[GAS_IDX_O2] = 0
	cm[GAS_IDX_N2] = 0
	cm[GAS_IDX_CO2] = 0
	cm[GAS_IDX_PLASMA] = 0
	cm[GAS_IDX_N2O] = 0
	cm[GAS_IDX_H2O] = 0
	cm[GAS_IDX_BZ] = 0
	cm[GAS_IDX_TRITIUM] = 0
	cm[GAS_IDX_MIASMA] = 0
	cm[GAS_IDX_FLUORINE] = 0
	var/list/acm = archived_core_moles
	if(!acm)
		archived_core_moles = NEW_CORE_MOLES
		acm = archived_core_moles
	acm[GAS_IDX_O2] = 0
	acm[GAS_IDX_N2] = 0
	acm[GAS_IDX_CO2] = 0
	acm[GAS_IDX_PLASMA] = 0
	acm[GAS_IDX_N2O] = 0
	acm[GAS_IDX_H2O] = 0
	acm[GAS_IDX_BZ] = 0
	acm[GAS_IDX_TRITIUM] = 0
	acm[GAS_IDX_MIASMA] = 0
	acm[GAS_IDX_FLUORINE] = 0
	rare_gases = null
	temperature = TCMB
	temperature_archived = TCMB
	volume = CELL_VOLUME
	last_share = 0
	min_heat_capacity = 0
	_immutable = FALSE
	_owner_pipeline = null
	simple_air = TRUE
	if(reaction_results)
		reaction_results.Cut()
	analyzer_results = null

// =============================================
// ACCESSORS
// =============================================

/// Get moles by gas string ID
/datum/gas_mixture/proc/get_moles(gas_id)
	var/idx = GLOB.gas_id_to_idx[gas_id]
	if(idx)
		return core_moles[idx]
	if(rare_gases)
		. = rare_gases[gas_id]
		if(!isnull(.))
			return
	return 0

/// Set moles by gas string ID
/datum/gas_mixture/proc/set_moles(gas_id, amt_val)
	if(_immutable)
		return
	var/idx = GLOB.gas_id_to_idx[gas_id]
	if(idx)
		core_moles[idx] = amt_val
		if(simple_air && idx > 2 && amt_val)
			simple_air = FALSE
		return
	// Rare gas
	if(amt_val > 0)
		if(!rare_gases)
			rare_gases = list()
		rare_gases[gas_id] = amt_val
		simple_air = FALSE
	else if(rare_gases)
		rare_gases -= gas_id
		if(!length(rare_gases))
			rare_gases = null

/// Add to moles of a gas
/datum/gas_mixture/proc/adjust_moles(id_val, num_val)
	if(_immutable)
		return
	var/idx = GLOB.gas_id_to_idx[id_val]
	if(idx)
		core_moles[idx] += num_val
		if(simple_air && idx > 2 && num_val)
			simple_air = FALSE
		return
	// Rare gas
	if(!rare_gases)
		rare_gases = list()
	rare_gases[id_val] += num_val
	if(num_val)
		simple_air = FALSE

/// Add moles with temperature blending
/datum/gas_mixture/proc/adjust_moles_temp(id_val, num_val, temp_val)
	if(_immutable)
		return
	if(num_val <= 0)
		// Just adjust, no heating needed
		adjust_moles(id_val, num_val)
		return
	// Blend temperature
	var/list/sh = GLOB.gas_data.specific_heats
	var/gas_sh = sh[id_val]
	var/self_hc = heat_capacity()
	var/giver_hc = num_val * gas_sh
	var/combined = self_hc + giver_hc
	if(combined > MINIMUM_HEAT_CAPACITY)
		temperature = (temperature * self_hc + temp_val * giver_hc) / combined
	adjust_moles(id_val, num_val)

/// Adjust multiple gases at once (varargs: id1, amt1, id2, amt2, ...)
/datum/gas_mixture/proc/adjust_multi(...)
	if(_immutable)
		return
	var/list/id_to_idx = GLOB.gas_id_to_idx
	var/list/cm = core_moles
	var/i = 1
	while(i < args.len)
		var/id_val = args[i]
		var/num_val = args[i + 1]
		var/idx = id_to_idx[id_val]
		if(idx)
			cm[idx] += num_val
			if(simple_air && idx > 2 && num_val)
				simple_air = FALSE
		else
			if(!rare_gases)
				rare_gases = list()
			rare_gases[id_val] += num_val
			if(num_val)
				simple_air = FALSE
		i += 2

/// Sum of all moles
/datum/gas_mixture/proc/total_moles()
	var/list/cm = core_moles
	. = cm[1] + cm[2] + cm[3] + cm[4] + cm[5] + cm[6] + cm[7] + cm[8] + cm[9] + cm[10]
	if(rare_gases)
		for(var/id as anything in rare_gases)
			. += rare_gases[id]

/// PV=nRT -> P = nRT/V
/datum/gas_mixture/proc/return_pressure()
	if(volume > 0)
		return total_moles() * R_IDEAL_GAS_EQUATION * temperature / volume
	return 0

/// Return temperature in kelvins
/datum/gas_mixture/proc/return_temperature()
	return temperature

/// Set temperature (min TCMB)
/datum/gas_mixture/proc/set_temperature(arg_temp)
	if(_immutable)
		return
	temperature = max(arg_temp, TCMB)

/// Return volume in liters
/datum/gas_mixture/proc/return_volume()
	return volume

/// Set volume
/datum/gas_mixture/proc/set_volume(vol_arg)
	volume = max(vol_arg, 0)

/// Sum of (moles * specific_heat) for all gases
/datum/gas_mixture/proc/heat_capacity()
	. = 0
	var/list/cm = core_moles
	var/list/sh = GLOB.gas_idx_to_specific_heat
	if(length(sh) < CORE_GAS_COUNT)
		. = min_heat_capacity
		return
	// Unrolled loop for core gases
	. += cm[1] * sh[1]
	. += cm[2] * sh[2]
	. += cm[3] * sh[3]
	. += cm[4] * sh[4]
	. += cm[5] * sh[5]
	. += cm[6] * sh[6]
	. += cm[7] * sh[7]
	. += cm[8] * sh[8]
	. += cm[9] * sh[9]
	. += cm[10] * sh[10]
	if(rare_gases)
		var/list/gas_sh = GLOB.gas_data.specific_heats
		for(var/id as anything in rare_gases)
			. += rare_gases[id] * gas_sh[id]
	if(. < min_heat_capacity)
		. = min_heat_capacity

/// Heat capacity contribution of one gas
/datum/gas_mixture/proc/partial_heat_capacity(gas_id)
	var/idx = GLOB.gas_id_to_idx[gas_id]
	if(idx)
		return core_moles[idx] * GLOB.gas_idx_to_specific_heat[idx]
	if(rare_gases && rare_gases[gas_id])
		return rare_gases[gas_id] * GLOB.gas_data.specific_heats[gas_id]
	return 0

/// Temperature * heat_capacity
/datum/gas_mixture/proc/thermal_energy()
	return temperature * heat_capacity()

/// Set minimum heat capacity (for vacuum heat capacity hack)
/datum/gas_mixture/proc/set_min_heat_capacity(arg_min)
	min_heat_capacity = arg_min

/// Returns list of gas string IDs present (moles > 0)
/datum/gas_mixture/proc/get_gases()
	. = list()
	var/list/cm = core_moles
	var/list/idx_to_id = GLOB.gas_idx_to_id
	for(var/i in 1 to CORE_GAS_COUNT)
		if(cm[i] > 0)
			. += idx_to_id[i]
	if(rare_gases)
		for(var/id as anything in rare_gases)
			if(rare_gases[id] > 0)
				. += id

/// Return last_share value
/datum/gas_mixture/proc/get_last_share()
	return last_share

/// Returns list of gas IDs matching the given flag
/datum/gas_mixture/proc/get_by_flag(flag_val)
	. = list()
	var/list/gas_flags = GLOB.gas_data.flags
	var/list/cm = core_moles
	var/list/idx_to_id = GLOB.gas_idx_to_id
	for(var/i in 1 to CORE_GAS_COUNT)
		if(cm[i] > 0)
			var/id = idx_to_id[i]
			if(gas_flags[id] & flag_val)
				. += id
	if(rare_gases)
		for(var/id as anything in rare_gases)
			if(rare_gases[id] > 0 && (gas_flags[id] & flag_val))
				. += id

/// Sum of (moles * oxidation_rate) for gases with oxidation_temperature < temp
/datum/gas_mixture/proc/get_oxidation_power(temp)
	. = 0
	var/list/ox_temps = GLOB.gas_data.oxidation_temperatures
	var/list/ox_rates = GLOB.gas_data.oxidation_rates
	var/list/cm = core_moles
	var/list/idx_to_id = GLOB.gas_idx_to_id
	for(var/i in 1 to CORE_GAS_COUNT)
		var/moles_val = cm[i]
		if(moles_val > 0)
			var/id = idx_to_id[i]
			var/ox_temp = ox_temps[id]
			if(ox_temp && temp > ox_temp)
				. += moles_val * ox_rates[id]
	if(rare_gases)
		for(var/id as anything in rare_gases)
			var/moles_val = rare_gases[id]
			if(moles_val > 0)
				var/ox_temp = ox_temps[id]
				if(ox_temp && temp > ox_temp)
					. += moles_val * ox_rates[id]

/// Sum of (moles / fire_burn_rate) for gases with fire_temperature < temp
/datum/gas_mixture/proc/get_fuel_amount(temp)
	. = 0
	var/list/fire_temps = GLOB.gas_data.fire_temperatures
	var/list/fire_rates = GLOB.gas_data.fire_burn_rates
	var/list/cm = core_moles
	var/list/idx_to_id = GLOB.gas_idx_to_id
	for(var/i in 1 to CORE_GAS_COUNT)
		var/moles_val = cm[i]
		if(moles_val > 0)
			var/id = idx_to_id[i]
			var/fire_temp = fire_temps[id]
			if(fire_temp && temp > fire_temp)
				. += moles_val / fire_rates[id]
	if(rare_gases)
		for(var/id as anything in rare_gases)
			var/moles_val = rare_gases[id]
			if(moles_val > 0)
				var/fire_temp = fire_temps[id]
				if(fire_temp && temp > fire_temp)
					. += moles_val / fire_rates[id]

// =============================================
// TRANSFER OPERATIONS
// =============================================

/// Merge another mixture into this one (temperature blending + mole transfer)
/datum/gas_mixture/proc/merge(datum/gas_mixture/giver)
	if(!giver)
		return FALSE
	if(_immutable)
		return FALSE

	// Heat transfer
	if(abs(temperature - giver.temperature) > MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER)
		var/self_hc = heat_capacity()
		var/giver_hc = giver.heat_capacity()
		var/combined_hc = self_hc + giver_hc
		if(combined_hc > MINIMUM_HEAT_CAPACITY)
			temperature = (giver.temperature * giver_hc + temperature * self_hc) / combined_hc

	// Core gas transfer
	var/list/cm = core_moles
	var/list/gcm = giver.core_moles
	if(!cm || !gcm)
		return FALSE
	cm[1] += gcm[1]
	cm[2] += gcm[2]
	cm[3] += gcm[3]
	cm[4] += gcm[4]
	cm[5] += gcm[5]
	cm[6] += gcm[6]
	cm[7] += gcm[7]
	cm[8] += gcm[8]
	cm[9] += gcm[9]
	cm[10] += gcm[10]

	// Rare gas transfer
	var/list/grg = giver.rare_gases
	if(grg)
		if(!rare_gases)
			rare_gases = grg.Copy()
		else
			for(var/id as anything in grg)
				rare_gases[id] += grg[id]

	if(simple_air && !giver.simple_air)
		simple_air = FALSE
	return TRUE

/// Remove amount moles proportionally, return new mixture from pool
/datum/gas_mixture/proc/remove(amount)
	if(!core_moles)
		return null
	var/sum = total_moles()
	amount = min(amount, sum)
	if(amount <= 0)
		return null
	var/ratio = amount / sum
	var/datum/gas_mixture/removed = gasmix_acquire(volume)
	removed.temperature = temperature
	removed.simple_air = simple_air

	// Core gases
	var/list/cm = core_moles
	var/list/rcm = removed.core_moles
	for(var/i in 1 to CORE_GAS_COUNT)
		var/val = QUANTIZE(cm[i] * ratio)
		rcm[i] = val
		cm[i] -= val

	// Rare gases
	if(rare_gases)
		var/list/rrg = null
		for(var/id as anything in rare_gases)
			var/val = QUANTIZE(rare_gases[id] * ratio)
			if(val > 0)
				if(!rrg)
					rrg = list()
				rrg[id] = val
			rare_gases[id] -= val
		removed.rare_gases = rrg
		// Garbage collect rare gases
		GAS_GARBAGE_COLLECT(rare_gases)
		if(!length(rare_gases))
			rare_gases = null

	return removed

/// Remove ratio fraction, return new mixture from pool
/datum/gas_mixture/proc/remove_ratio(ratio)
	if(ratio <= 0 || !core_moles)
		return null
	ratio = min(ratio, 1)

	var/datum/gas_mixture/removed = gasmix_acquire(volume)
	removed.temperature = temperature
	removed.simple_air = simple_air

	// Core gases
	var/list/cm = core_moles
	var/list/rcm = removed.core_moles
	for(var/i in 1 to CORE_GAS_COUNT)
		var/val = QUANTIZE(cm[i] * ratio)
		rcm[i] = val
		cm[i] -= val

	// Rare gases
	if(rare_gases)
		var/list/rrg = null
		for(var/id as anything in rare_gases)
			var/val = QUANTIZE(rare_gases[id] * ratio)
			if(val > 0)
				if(!rrg)
					rrg = list()
				rrg[id] = val
			rare_gases[id] -= val
		removed.rare_gases = rrg
		GAS_GARBAGE_COLLECT(rare_gases)
		if(!length(rare_gases))
			rare_gases = null

	return removed

/// Internal remove by flag implementation
/datum/gas_mixture/proc/__remove_by_flag(datum/gas_mixture/into, flag_val, amount_val)
	if(!into)
		return
	var/list/gas_flags = GLOB.gas_data.flags
	var/list/idx_to_id = GLOB.gas_idx_to_id

	// Calculate total moles matching the flag
	var/sum = 0
	var/list/cm = core_moles
	for(var/i in 1 to CORE_GAS_COUNT)
		if(cm[i] > 0 && (gas_flags[idx_to_id[i]] & flag_val))
			sum += cm[i]
	if(rare_gases)
		for(var/id as anything in rare_gases)
			if(rare_gases[id] > 0 && (gas_flags[id] & flag_val))
				sum += rare_gases[id]

	if(sum <= 0)
		return

	var/ratio = min(1, amount_val / sum)
	into.temperature = temperature

	var/list/icm = into.core_moles
	for(var/i in 1 to CORE_GAS_COUNT)
		if(cm[i] > 0 && (gas_flags[idx_to_id[i]] & flag_val))
			var/val = QUANTIZE(cm[i] * ratio)
			icm[i] = val
			cm[i] -= val

	if(rare_gases)
		for(var/id as anything in rare_gases)
			if(rare_gases[id] > 0 && (gas_flags[id] & flag_val))
				var/val = QUANTIZE(rare_gases[id] * ratio)
				if(val > 0)
					if(!into.rare_gases)
						into.rare_gases = list()
					into.rare_gases[id] = val
				rare_gases[id] -= val
		GAS_GARBAGE_COLLECT(rare_gases)
		if(!length(rare_gases))
			rare_gases = null

/// Public remove_by_flag wrapper — creates the target from pool
/datum/gas_mixture/proc/remove_by_flag(flag, amount)
	var/datum/gas_mixture/removed = gasmix_acquire(volume)
	__remove_by_flag(removed, flag, amount)
	return removed

/// Return a pool-acquired copy
/datum/gas_mixture/proc/copy()
	var/datum/gas_mixture/copy = gasmix_acquire(volume)
	copy.copy_from(src)
	return copy

/// Copy all data from giver into self
/datum/gas_mixture/proc/copy_from(datum/gas_mixture/giver)
	if(!giver)
		return FALSE
	// Core moles — element copy
	var/list/cm = core_moles
	var/list/gcm = giver.core_moles
	if(!cm || !gcm)
		return FALSE
	cm[1] = gcm[1]
	cm[2] = gcm[2]
	cm[3] = gcm[3]
	cm[4] = gcm[4]
	cm[5] = gcm[5]
	cm[6] = gcm[6]
	cm[7] = gcm[7]
	cm[8] = gcm[8]
	cm[9] = gcm[9]
	cm[10] = gcm[10]
	// Rare gases
	if(giver.rare_gases)
		rare_gases = giver.rare_gases.Copy()
	else
		rare_gases = null
	temperature = giver.temperature
	simple_air = giver.simple_air
	return TRUE

/// Initialize from turf's initial_gas_mix
/datum/gas_mixture/proc/copy_from_turf(turf/model)
	parse_gas_string(model.initial_gas_mix)

	// Account for changes in initial_temperature
	var/turf/model_parent = model.parent_type
	if(model.initial_temperature != initial(model.initial_temperature) || model.initial_temperature != initial(model_parent.initial_temperature))
		temperature = model.initial_temperature

	return TRUE

/// Move moles to other mixture
/datum/gas_mixture/proc/transfer_to(datum/gas_mixture/other, moles)
	var/datum/gas_mixture/removed = remove(moles)
	if(!removed)
		return FALSE
	other.merge(removed)
	gasmix_release(removed)
	return TRUE

/// Move ratio to other mixture
/datum/gas_mixture/proc/transfer_ratio_to(datum/gas_mixture/other, ratio)
	var/datum/gas_mixture/removed = remove_ratio(ratio)
	if(!removed)
		return FALSE
	other.merge(removed)
	gasmix_release(removed)
	return TRUE

/// Selective scrubbing: move ratio of specified gases into target
/datum/gas_mixture/proc/scrub_into(datum/gas_mixture/into, ratio_v, gas_list)
	if(!into)
		return FALSE
	if(_immutable)
		return FALSE

	var/list/id_to_idx = GLOB.gas_id_to_idx
	var/list/cm = core_moles

	// Early bailout: skip pool allocation if no matching gases have significant moles
	var/any_match = FALSE
	for(var/target_gas as anything in gas_list)
		var/idx = id_to_idx[target_gas]
		if(idx)
			if(cm[idx] > MINIMUM_MOLE_COUNT)
				any_match = TRUE
				break
		else if(rare_gases?[target_gas] > MINIMUM_MOLE_COUNT)
			any_match = TRUE
			break
	if(!any_match)
		return FALSE

	var/datum/gas_mixture/filtered = gasmix_acquire(volume)
	filtered.temperature = temperature
	var/list/fcm = filtered.core_moles

	for(var/target_gas as anything in gas_list)
		var/idx = id_to_idx[target_gas]
		if(idx)
			var/val = QUANTIZE(cm[idx] * ratio_v)
			fcm[idx] = val
			cm[idx] -= val
		else if(rare_gases && rare_gases[target_gas])
			var/val = QUANTIZE(rare_gases[target_gas] * ratio_v)
			if(val > 0)
				if(!filtered.rare_gases)
					filtered.rare_gases = list()
				filtered.rare_gases[target_gas] = val
			rare_gases[target_gas] -= val

	into.merge(filtered)
	gasmix_release(filtered)

	// Clean up rare gases
	if(rare_gases)
		GAS_GARBAGE_COLLECT(rare_gases)
		if(!length(rare_gases))
			rare_gases = null
	UPDATE_SIMPLE_AIR(src)
	return TRUE

// =============================================
// PROCESSING
// =============================================

/// THE critical proc. Gas sharing between adjacent tiles. Uses archived values. Returns pressure delta for spacewind.
/// Fully unrolled for maximum performance — called ~7000 times per tick.
/datum/gas_mixture/proc/share(datum/gas_mixture/sharer, atmos_adjacent_turfs = 4)
	var/list/cm = core_moles
	var/list/scm = sharer.core_moles
	var/list/acm = archived_core_moles
	var/list/sacm = sharer.archived_core_moles

	var/temperature_delta = temperature_archived - sharer.temperature_archived
	var/abs_temperature_delta = abs(temperature_delta)

	var/moved_moles = 0
	var/abs_moved_moles = 0
	var/divisor = atmos_adjacent_turfs + 1
	var/delta
	var/sharer_immutable = sharer._immutable

	// Short-circuit: if both sides have identical archived air, skip entirely
	if(acm[1] == sacm[1] && acm[2] == sacm[2] && abs_temperature_delta <= MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER)
		if(acm[3] == sacm[3] && acm[4] == sacm[4] && acm[5] == sacm[5] && \
		   acm[6] == sacm[6] && acm[7] == sacm[7] && acm[8] == sacm[8] && \
		   acm[9] == sacm[9] && acm[10] == sacm[10] && !rare_gases && !sharer.rare_gases)
			last_share = 0
#ifdef TESTING
			SSair.prof_share_calls++
			SSair.prof_share_short_circuit++
#endif
			return 0

	// SUPER-FAST PATH: both sides only have O2+N2, isothermal, no rare gases
	// Skips 8 gas checks — applies to ~80% of station turfs
	if(simple_air && sharer.simple_air && abs_temperature_delta <= MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER)
#ifdef TESTING
		SSair.prof_share_calls++
		SSair.prof_share_simple++
#endif
		// O2 (1)
		delta = QUANTIZE(acm[1] - sacm[1]) / divisor
		if(delta)
			cm[1] -= delta
			if(!sharer_immutable)
				scm[1] += delta
			moved_moles += delta
			abs_moved_moles += abs(delta)
		// N2 (2)
		delta = QUANTIZE(acm[2] - sacm[2]) / divisor
		if(delta)
			cm[2] -= delta
			if(!sharer_immutable)
				scm[2] += delta
			moved_moles += delta
			abs_moved_moles += abs(delta)
		last_share = abs_moved_moles
		if(abs_temperature_delta > MINIMUM_TEMPERATURE_TO_MOVE || abs(moved_moles) > MINIMUM_MOLES_DELTA_TO_MOVE)
			var/our_moles = cm[1] + cm[2]
			var/their_moles = scm[1] + scm[2]
			return (temperature_archived * (our_moles + moved_moles) - sharer.temperature_archived * (their_moles - moved_moles)) * R_IDEAL_GAS_EQUATION / volume
		return 0

	var/old_self_hc = 0
	var/old_sharer_hc = 0
	var/hc_self_to_sharer = 0
	var/hc_sharer_to_self = 0

	// ---- Core gas transfer: unrolled, split into fast path (no temp delta) and slow path ----
#ifdef TESTING
	SSair.prof_share_calls++
#endif
	if(abs_temperature_delta <= MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER)
#ifdef TESTING
		SSair.prof_share_isothermal++
#endif
		// FAST PATH: no temperature blending needed (overwhelmingly common on station)
		// O2 (1) — always present
		delta = QUANTIZE(acm[1] - sacm[1]) / divisor
		if(delta)
			cm[1] -= delta
			if(!sharer_immutable)
				scm[1] += delta
			moved_moles += delta
			abs_moved_moles += abs(delta)
		// N2 (2) — always present
		delta = QUANTIZE(acm[2] - sacm[2]) / divisor
		if(delta)
			cm[2] -= delta
			if(!sharer_immutable)
				scm[2] += delta
			moved_moles += delta
			abs_moved_moles += abs(delta)
		// CO2 (3) — skip QUANTIZE if both zero
		if(acm[3] || sacm[3])
			delta = QUANTIZE(acm[3] - sacm[3]) / divisor
			if(delta)
				cm[3] -= delta
				if(!sharer_immutable)
					scm[3] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// Plasma (4)
		if(acm[4] || sacm[4])
			delta = QUANTIZE(acm[4] - sacm[4]) / divisor
			if(delta)
				cm[4] -= delta
				if(!sharer_immutable)
					scm[4] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// N2O (5)
		if(acm[5] || sacm[5])
			delta = QUANTIZE(acm[5] - sacm[5]) / divisor
			if(delta)
				cm[5] -= delta
				if(!sharer_immutable)
					scm[5] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// H2O (6)
		if(acm[6] || sacm[6])
			delta = QUANTIZE(acm[6] - sacm[6]) / divisor
			if(delta)
				cm[6] -= delta
				if(!sharer_immutable)
					scm[6] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// BZ (7)
		if(acm[7] || sacm[7])
			delta = QUANTIZE(acm[7] - sacm[7]) / divisor
			if(delta)
				cm[7] -= delta
				if(!sharer_immutable)
					scm[7] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// Tritium (8)
		if(acm[8] || sacm[8])
			delta = QUANTIZE(acm[8] - sacm[8]) / divisor
			if(delta)
				cm[8] -= delta
				if(!sharer_immutable)
					scm[8] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// Miasma (9)
		if(acm[9] || sacm[9])
			delta = QUANTIZE(acm[9] - sacm[9]) / divisor
			if(delta)
				cm[9] -= delta
				if(!sharer_immutable)
					scm[9] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// Fluorine (10)
		if(acm[10] || sacm[10])
			delta = QUANTIZE(acm[10] - sacm[10]) / divisor
			if(delta)
				cm[10] -= delta
				if(!sharer_immutable)
					scm[10] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
	else
#ifdef TESTING
		SSair.prof_share_thermal++
#endif
		// SLOW PATH: temperature differs, must track heat capacity transfer
		old_self_hc = heat_capacity()
		old_sharer_hc = sharer.heat_capacity()
		var/list/sh = GLOB.gas_idx_to_specific_heat
		var/ghc
		// O2 (1)
		delta = QUANTIZE(acm[1] - sacm[1]) / divisor
		if(delta)
			ghc = delta * sh[1]
			if(delta > 0)
				hc_self_to_sharer += ghc
			else
				hc_sharer_to_self -= ghc
			cm[1] -= delta
			if(!sharer_immutable)
				scm[1] += delta
			moved_moles += delta
			abs_moved_moles += abs(delta)
		// N2 (2)
		delta = QUANTIZE(acm[2] - sacm[2]) / divisor
		if(delta)
			ghc = delta * sh[2]
			if(delta > 0)
				hc_self_to_sharer += ghc
			else
				hc_sharer_to_self -= ghc
			cm[2] -= delta
			if(!sharer_immutable)
				scm[2] += delta
			moved_moles += delta
			abs_moved_moles += abs(delta)
		// CO2 (3)
		if(acm[3] || sacm[3])
			delta = QUANTIZE(acm[3] - sacm[3]) / divisor
			if(delta)
				ghc = delta * sh[3]
				if(delta > 0)
					hc_self_to_sharer += ghc
				else
					hc_sharer_to_self -= ghc
				cm[3] -= delta
				if(!sharer_immutable)
					scm[3] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// Plasma (4)
		if(acm[4] || sacm[4])
			delta = QUANTIZE(acm[4] - sacm[4]) / divisor
			if(delta)
				ghc = delta * sh[4]
				if(delta > 0)
					hc_self_to_sharer += ghc
				else
					hc_sharer_to_self -= ghc
				cm[4] -= delta
				if(!sharer_immutable)
					scm[4] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// N2O (5)
		if(acm[5] || sacm[5])
			delta = QUANTIZE(acm[5] - sacm[5]) / divisor
			if(delta)
				ghc = delta * sh[5]
				if(delta > 0)
					hc_self_to_sharer += ghc
				else
					hc_sharer_to_self -= ghc
				cm[5] -= delta
				if(!sharer_immutable)
					scm[5] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// H2O (6)
		if(acm[6] || sacm[6])
			delta = QUANTIZE(acm[6] - sacm[6]) / divisor
			if(delta)
				ghc = delta * sh[6]
				if(delta > 0)
					hc_self_to_sharer += ghc
				else
					hc_sharer_to_self -= ghc
				cm[6] -= delta
				if(!sharer_immutable)
					scm[6] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// BZ (7)
		if(acm[7] || sacm[7])
			delta = QUANTIZE(acm[7] - sacm[7]) / divisor
			if(delta)
				ghc = delta * sh[7]
				if(delta > 0)
					hc_self_to_sharer += ghc
				else
					hc_sharer_to_self -= ghc
				cm[7] -= delta
				if(!sharer_immutable)
					scm[7] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// Tritium (8)
		if(acm[8] || sacm[8])
			delta = QUANTIZE(acm[8] - sacm[8]) / divisor
			if(delta)
				ghc = delta * sh[8]
				if(delta > 0)
					hc_self_to_sharer += ghc
				else
					hc_sharer_to_self -= ghc
				cm[8] -= delta
				if(!sharer_immutable)
					scm[8] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// Miasma (9)
		if(acm[9] || sacm[9])
			delta = QUANTIZE(acm[9] - sacm[9]) / divisor
			if(delta)
				ghc = delta * sh[9]
				if(delta > 0)
					hc_self_to_sharer += ghc
				else
					hc_sharer_to_self -= ghc
				cm[9] -= delta
				if(!sharer_immutable)
					scm[9] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)
		// Fluorine (10)
		if(acm[10] || sacm[10])
			delta = QUANTIZE(acm[10] - sacm[10]) / divisor
			if(delta)
				ghc = delta * sh[10]
				if(delta > 0)
					hc_self_to_sharer += ghc
				else
					hc_sharer_to_self -= ghc
				cm[10] -= delta
				if(!sharer_immutable)
					scm[10] += delta
				moved_moles += delta
				abs_moved_moles += abs(delta)

	// Rare gas transfer — iterate each side separately to avoid allocating a union list
	var/list/rg = rare_gases
	var/list/srg = sharer.rare_gases
	if(rg || srg)
		var/list/gas_sh = GLOB.gas_data.specific_heats
		// First pass: iterate self's rare gases
		if(rg)
			for(var/id as anything in rg)
				var/archived_self = rg[id]
				var/archived_sharer = srg ? (srg[id] || 0) : 0
				delta = QUANTIZE(archived_self - archived_sharer) / divisor
				if(delta)
					if(abs_temperature_delta > MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER)
						var/ghc = delta * gas_sh[id]
						if(delta > 0)
							hc_self_to_sharer += ghc
						else
							hc_sharer_to_self -= ghc
					rg[id] -= delta
					if(!sharer_immutable)
						if(!srg)
							srg = list()
							sharer.rare_gases = srg
						srg[id] = (srg[id] || 0) + delta
					moved_moles += delta
					abs_moved_moles += abs(delta)
		// Second pass: iterate sharer's rare gases not already in self
		if(srg)
			for(var/id as anything in srg)
				if(rg && !isnull(rg[id]))
					continue // Already handled in first pass
				var/archived_sharer = srg[id]
				delta = QUANTIZE(-archived_sharer) / divisor
				if(delta)
					if(abs_temperature_delta > MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER)
						var/ghc = delta * gas_sh[id]
						if(delta > 0)
							hc_self_to_sharer += ghc
						else
							hc_sharer_to_self -= ghc
					if(!rg)
						rg = list()
						rare_gases = rg
					rg[id] = (rg[id] || 0) - delta
					if(!sharer_immutable)
						srg[id] += delta
					moved_moles += delta
					abs_moved_moles += abs(delta)
		// Garbage collect rare gases
		if(rg)
			GAS_GARBAGE_COLLECT(rg)
			if(!length(rg))
				rare_gases = null
		if(srg && !sharer_immutable)
			GAS_GARBAGE_COLLECT(srg)
			if(!length(srg))
				sharer.rare_gases = null

	last_share = min(abs_moved_moles, 1000)
	// Update simple_air flags after gas transfer between non-matching turfs
	// Note: if both were simple_air, they took the super-fast path (only O2/N2) and remain simple
	if(abs_moved_moles && (simple_air != sharer.simple_air))
		UPDATE_SIMPLE_AIR(src)
		if(!sharer_immutable)
			UPDATE_SIMPLE_AIR(sharer)

	// Thermal energy transfer
	if(abs_temperature_delta > MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER)
		var/new_self_hc = old_self_hc + hc_sharer_to_self - hc_self_to_sharer
		var/new_sharer_hc = old_sharer_hc + hc_self_to_sharer - hc_sharer_to_self

		if(new_self_hc > MINIMUM_HEAT_CAPACITY)
			temperature = (old_self_hc * temperature - hc_self_to_sharer * temperature_archived + hc_sharer_to_self * sharer.temperature_archived) / new_self_hc

		if(!sharer_immutable)
			if(new_sharer_hc > MINIMUM_HEAT_CAPACITY)
				sharer.temperature = (old_sharer_hc * sharer.temperature - hc_sharer_to_self * sharer.temperature_archived + hc_self_to_sharer * temperature_archived) / new_sharer_hc

				if(abs(old_sharer_hc) > MINIMUM_HEAT_CAPACITY)
					if(abs(new_sharer_hc / old_sharer_hc - 1) < 0.1)
						temperature_share(sharer, OPEN_HEAT_TRANSFER_COEFFICIENT)

	if(temperature_delta > MINIMUM_TEMPERATURE_TO_MOVE || abs(moved_moles) > MINIMUM_MOLES_DELTA_TO_MOVE)
		var/our_moles = total_moles()
		var/their_moles = sharer.total_moles()
		return (temperature_archived * (our_moles + moved_moles) - sharer.temperature_archived * (their_moles - moved_moles)) * R_IDEAL_GAS_EQUATION / volume

	return 0

/// Save current state to archived vars
/datum/gas_mixture/proc/archive()
	if(_immutable)
		return
	var/list/cm = core_moles
	var/list/acm = archived_core_moles
#ifdef TESTING
	SSair.prof_archive_calls++
#endif
	if(simple_air)
#ifdef TESTING
		SSair.prof_archive_simple++
#endif
		// Fast path: only O2+N2 present, skip 8 zero-to-zero copies
		acm[1] = cm[1]
		acm[2] = cm[2]
	else
#ifdef TESTING
		SSair.prof_archive_full++
#endif
		// Full 10-element copy (element-by-element faster than list.Copy() which allocates a new list)
		acm[1] = cm[1]
		acm[2] = cm[2]
		acm[3] = cm[3]
		acm[4] = cm[4]
		acm[5] = cm[5]
		acm[6] = cm[6]
		acm[7] = cm[7]
		acm[8] = cm[8]
		acm[9] = cm[9]
		acm[10] = cm[10]
	temperature_archived = temperature
	return TRUE

/// Compare with another mixture, return gas ID that differs or "temp" or ""
/datum/gas_mixture/proc/compare(datum/gas_mixture/sample)
	if(!sample)
		return ""

	var/list/cm = core_moles
	var/list/scm = sample.core_moles
	var/list/idx_to_id = GLOB.gas_idx_to_id

	for(var/i in 1 to CORE_GAS_COUNT)
		var/gas_moles = cm[i]
		var/sample_moles = scm[i]
		var/delta = abs(gas_moles - sample_moles)
		if(delta > MINIMUM_MOLES_DELTA_TO_MOVE && delta > gas_moles * MINIMUM_AIR_RATIO_TO_MOVE)
			return idx_to_id[i]

	// Check rare gases
	var/list/rg = rare_gases
	var/list/srg = sample.rare_gases
	if(rg || srg)
		var/list/all_rare = list()
		if(rg)
			all_rare |= rg
		if(srg)
			all_rare |= srg
		for(var/id as anything in all_rare)
			var/gas_moles = rg ? (rg[id] || 0) : 0
			var/sample_moles = srg ? (srg[id] || 0) : 0
			var/delta = abs(gas_moles - sample_moles)
			if(delta > MINIMUM_MOLES_DELTA_TO_MOVE && delta > gas_moles * MINIMUM_AIR_RATIO_TO_MOVE)
				return id

	var/our_moles = total_moles()
	if(our_moles > MINIMUM_MOLES_DELTA_TO_MOVE)
		if(abs(temperature - sample.temperature) > MINIMUM_TEMPERATURE_DELTA_TO_SUSPEND)
			return "temp"

	return ""

/// Heat conduction between self and sharer (or a surface with given temp/hc)
/datum/gas_mixture/proc/temperature_share(datum/gas_mixture/sharer, conduction_coefficient, sharer_temperature, sharer_heat_capacity)
	if(sharer)
		sharer_temperature = sharer.temperature_archived
	var/temperature_delta = temperature_archived - sharer_temperature
	if(abs(temperature_delta) > MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER)
		var/self_hc = heat_capacity()
		if(!sharer_heat_capacity)
			sharer_heat_capacity = sharer ? sharer.heat_capacity() : 0

		if((sharer_heat_capacity > MINIMUM_HEAT_CAPACITY) && (self_hc > MINIMUM_HEAT_CAPACITY))
			var/heat = conduction_coefficient * temperature_delta * (self_hc * sharer_heat_capacity / (self_hc + sharer_heat_capacity))
			temperature = max(temperature - heat / self_hc, TCMB)
			sharer_temperature = max(sharer_temperature + heat / sharer_heat_capacity, TCMB)
			if(sharer)
				sharer.temperature = sharer_temperature
	return sharer_temperature

/// Run gas reactions, return reaction flags
/datum/gas_mixture/proc/react(datum/holder)
	. = NO_REACTION
	// No reaction can fire with only O2+N2 — skip the entire reaction loop
	if(simple_air)
#ifdef TESTING
		SSair.prof_react_simple_skipped++
#endif
		return
	var/tm = total_moles()
	if(!tm)
		return
	if(!length(SSair.gas_reactions))
		return

	reaction_results = list()
	var/temp = temperature
	var/ener = thermal_energy()

	for(var/r as anything in SSair.gas_reactions)
		var/datum/gas_reaction/reaction = r
		var/list/min_reqs = reaction.min_requirements
#ifdef TESTING
		SSair.prof_reactions_checked++
#endif

		// Check TEMP requirement
		if(min_reqs["TEMP"] && temp < min_reqs["TEMP"])
			continue
		// Check MAX_TEMP requirement
		if(min_reqs["MAX_TEMP"] && temp > min_reqs["MAX_TEMP"])
			continue
		// Check ENER requirement
		if(min_reqs["ENER"] && ener < min_reqs["ENER"])
			continue

		var/failed = FALSE
		for(var/id in min_reqs)
			if(id == "TEMP" || id == "ENER" || id == "MAX_TEMP")
				continue
			if(get_moles(id) < min_reqs[id])
				failed = TRUE
				break
		if(failed)
			continue

		// All requirements met
		. |= reaction.react(src, holder)
#ifdef TESTING
		SSair.prof_reactions_fired++
#endif
		if(. & STOP_REACTIONS)
			break

		// Update cached values after each reaction
		temp = temperature
		ener = thermal_energy()

/// Adjust thermal energy by amount
/datum/gas_mixture/proc/adjust_heat(temp_delta)
	if(_immutable)
		return
	var/hc = heat_capacity()
	if(hc > MINIMUM_HEAT_CAPACITY)
		temperature = max(temperature + temp_delta / hc, TCMB)

// =============================================
// UTILITY
// =============================================

/// Zero everything
/datum/gas_mixture/proc/clear()
	if(_immutable)
		return
	var/list/cm = core_moles
	cm[1] = 0
	cm[2] = 0
	cm[3] = 0
	cm[4] = 0
	cm[5] = 0
	cm[6] = 0
	cm[7] = 0
	cm[8] = 0
	cm[9] = 0
	cm[10] = 0
	rare_gases = null
	temperature = TCMB
	simple_air = TRUE

/// Set immutable flag
/datum/gas_mixture/proc/mark_immutable()
	_immutable = TRUE

/// Multiply all moles by a factor
/datum/gas_mixture/proc/multiply(num_val)
	if(_immutable)
		return
	var/list/cm = core_moles
	if(!cm)
		return
	cm[1] *= num_val
	cm[2] *= num_val
	cm[3] *= num_val
	cm[4] *= num_val
	cm[5] *= num_val
	cm[6] *= num_val
	cm[7] *= num_val
	cm[8] *= num_val
	cm[9] *= num_val
	cm[10] *= num_val
	if(rare_gases)
		for(var/id as anything in rare_gases)
			rare_gases[id] *= num_val

/// Divide all moles by a factor
/datum/gas_mixture/proc/divide(num_val)
	if(_immutable || !num_val)
		return
	var/list/cm = core_moles
	cm[1] /= num_val
	cm[2] /= num_val
	cm[3] /= num_val
	cm[4] /= num_val
	cm[5] /= num_val
	cm[6] /= num_val
	cm[7] /= num_val
	cm[8] /= num_val
	cm[9] /= num_val
	cm[10] /= num_val
	if(rare_gases)
		for(var/id as anything in rare_gases)
			rare_gases[id] /= num_val

/// Add to all moles
/datum/gas_mixture/proc/add(num_val)
	if(_immutable)
		return
	var/list/cm = core_moles
	cm[1] += num_val
	cm[2] += num_val
	cm[3] += num_val
	cm[4] += num_val
	cm[5] += num_val
	cm[6] += num_val
	cm[7] += num_val
	cm[8] += num_val
	cm[9] += num_val
	cm[10] += num_val
	if(rare_gases)
		for(var/id as anything in rare_gases)
			rare_gases[id] += num_val

/// Subtract from all moles
/datum/gas_mixture/proc/subtract(num_val)
	if(_immutable)
		return
	var/list/cm = core_moles
	cm[1] -= num_val
	cm[2] -= num_val
	cm[3] -= num_val
	cm[4] -= num_val
	cm[5] -= num_val
	cm[6] -= num_val
	cm[7] -= num_val
	cm[8] -= num_val
	cm[9] -= num_val
	cm[10] -= num_val
	if(rare_gases)
		for(var/id as anything in rare_gases)
			rare_gases[id] -= num_val

/// Parse "o2=21.78;n2=82.36;TEMP=293.15" format
/datum/gas_mixture/proc/parse_gas_string(gas_string)
	if(_immutable)
		return FALSE
	gas_string = SSair.preprocess_gas_string(gas_string)
	var/list/gas = params2list(gas_string)
	// Clear first, then set values
	clear()
	if(gas["TEMP"])
		var/temp = text2num(gas["TEMP"])
		gas -= "TEMP"
		if(!isnum(temp) || temp < TCMB)
			temp = TCMB
		temperature = temp
	for(var/id in gas)
		var/amt = text2num(gas[id])
		if(amt)
			set_moles(id, amt)
	UPDATE_SIMPLE_AIR(src)
	archive()
	return TRUE

/// Keep existing
/datum/gas_mixture/proc/set_analyzer_results(instability)
	if(!analyzer_results)
		analyzer_results = list()
	analyzer_results["fusion"] = instability

/// Equalize self with a total mixture (set self to average of total / N where N is implicit from total)
/datum/gas_mixture/proc/equalize_with(datum/gas_mixture/total)
	if(!total || _immutable)
		return
	copy_from(total)

// =============================================
// VV SUPPORT
// =============================================

/datum/gas_mixture/vv_edit_var(var_name, var_value)
	if(var_name == NAMEOF(src, gas_list_view_only))
		return FALSE
	if(var_name == NAMEOF(src, core_moles))
		return FALSE
	if(var_name == NAMEOF(src, archived_core_moles))
		return FALSE
	return ..()

/datum/gas_mixture/vv_get_var(var_name)
	. = ..()
	if(var_name == NAMEOF(src, gas_list_view_only))
		var/list/dummy = get_gases()
		for(var/gas in dummy)
			dummy[gas] = get_moles(gas)
			dummy["CAP [gas]"] = partial_heat_capacity(gas)
		dummy["TEMP"] = return_temperature()
		dummy["PRESSURE"] = return_pressure()
		dummy["HEAT CAPACITY"] = heat_capacity()
		dummy["TOTAL MOLES"] = total_moles()
		dummy["VOLUME"] = return_volume()
		dummy["THERMAL ENERGY"] = thermal_energy()
		return debug_variable("gases (READ ONLY)", dummy, 0, src)

/datum/gas_mixture/vv_get_dropdown()
	. = ..()
	VV_DROPDOWN_OPTION("", "---")
	VV_DROPDOWN_OPTION(VV_HK_PARSE_GASSTRING, "Parse Gas String")
	VV_DROPDOWN_OPTION(VV_HK_EMPTY, "Empty")
	VV_DROPDOWN_OPTION(VV_HK_SET_MOLES, "Set Moles")
	VV_DROPDOWN_OPTION(VV_HK_SET_TEMPERATURE, "Set Temperature")
	VV_DROPDOWN_OPTION(VV_HK_SET_VOLUME, "Set Volume")

/datum/gas_mixture/vv_do_topic(list/href_list)
	. = ..()
	if(!.)
		return
	if(href_list[VV_HK_PARSE_GASSTRING])
		var/gasstring = input(usr, "Input Gas String (WARNING: Advanced. Don't use this unless you know how these work.", "Gas String Parse") as text|null
		if(!istext(gasstring))
			return
		log_admin("[key_name(usr)] modified gas mixture [REF(src)]: Set to gas string [gasstring].")
		message_admins("[key_name(usr)] modified gas mixture [REF(src)]: Set to gas string [gasstring].")
		parse_gas_string(gasstring)
	if(href_list[VV_HK_EMPTY])
		log_admin("[key_name(usr)] emptied gas mixture [REF(src)].")
		message_admins("[key_name(usr)] emptied gas mixture [REF(src)].")
		clear()
	if(href_list[VV_HK_SET_MOLES])
		var/list/gases = get_gases()
		for(var/gas in gases)
			gases[gas] = get_moles(gas)
		var/gasid = input(usr, "What kind of gas?", "Set Gas") as null|anything in GLOB.gas_data.ids
		if(!gasid)
			return
		var/amount = input(usr, "Input amount", "Set Gas", gases[gasid] || 0) as num|null
		if(!isnum(amount))
			return
		amount = max(0, amount)
		log_admin("[key_name(usr)] modified gas mixture [REF(src)]: Set gas [gasid] to [amount] moles.")
		message_admins("[key_name(usr)] modified gas mixture [REF(src)]: Set gas [gasid] to [amount] moles.")
		set_moles(gasid, amount)
	if(href_list[VV_HK_SET_TEMPERATURE])
		var/temp = input(usr, "Set the temperature of this mixture to?", "Set Temperature", return_temperature()) as num|null
		if(!isnum(temp))
			return
		temp = max(2.7, temp)
		log_admin("[key_name(usr)] modified gas mixture [REF(src)]: Changed temperature to [temp].")
		message_admins("[key_name(usr)] modified gas mixture [REF(src)]: Changed temperature to [temp].")
		set_temperature(temp)
	if(href_list[VV_HK_SET_VOLUME])
		var/vol = input(usr, "Set the volume of this mixture to?", "Set Volume", return_volume()) as num|null
		if(!isnum(vol))
			return
		vol = max(0, vol)
		log_admin("[key_name(usr)] modified gas mixture [REF(src)]: Changed volume to [vol].")
		message_admins("[key_name(usr)] modified gas mixture [REF(src)]: Changed volume to [vol].")
		set_volume(vol)

// VV WRAPPERS
/datum/gas_mixture/proc/vv_set_moles(gas_type, moles)
	return set_moles(gas_type, moles)
/datum/gas_mixture/proc/vv_get_moles(gas_type)
	return get_moles(gas_type)
/datum/gas_mixture/proc/vv_set_temperature(new_temp)
	return set_temperature(new_temp)
/datum/gas_mixture/proc/vv_set_volume(new_volume)
	return set_volume(new_volume)
/datum/gas_mixture/proc/vv_react(datum/holder)
	return react(holder)

// =============================================
// SUBTYPE: /datum/gas_mixture/turf
// =============================================

/// Turf gas mixture — returns HEAT_CAPACITY_VACUUM when empty (no gases present)
/datum/gas_mixture/turf

/datum/gas_mixture/turf/heat_capacity()
	. = 0
	var/list/cm = core_moles
	var/list/sh = GLOB.gas_idx_to_specific_heat
	. += cm[1] * sh[1]
	. += cm[2] * sh[2]
	. += cm[3] * sh[3]
	. += cm[4] * sh[4]
	. += cm[5] * sh[5]
	. += cm[6] * sh[6]
	. += cm[7] * sh[7]
	. += cm[8] * sh[8]
	. += cm[9] * sh[9]
	. += cm[10] * sh[10]
	if(rare_gases)
		var/list/gas_sh = GLOB.gas_data.specific_heats
		for(var/id as anything in rare_gases)
			. += rare_gases[id] * gas_sh[id]
	if(!.)
		. = HEAT_CAPACITY_VACUUM
	else if(. < min_heat_capacity)
		. = min_heat_capacity

// =============================================
// GLOBAL PROCS
// =============================================

/// Equalize all gas_mixtures in a list
/proc/equalize_all_gases_in_list(list/gas_list)
	if(!length(gas_list))
		return

	// Calculate totals
	var/total_volume = 0
	var/total_thermal_energy = 0
	var/list/total_core = NEW_CORE_MOLES
	var/list/total_rare = null

	for(var/datum/gas_mixture/gm as anything in gas_list)
		if(!gm || !gm.core_moles)
			continue
		total_volume += gm.volume
		total_thermal_energy += gm.thermal_energy()
		var/list/gcm = gm.core_moles
		total_core[1] += gcm[1]
		total_core[2] += gcm[2]
		total_core[3] += gcm[3]
		total_core[4] += gcm[4]
		total_core[5] += gcm[5]
		total_core[6] += gcm[6]
		total_core[7] += gcm[7]
		total_core[8] += gcm[8]
		total_core[9] += gcm[9]
		total_core[10] += gcm[10]
		if(gm.rare_gases)
			if(!total_rare)
				total_rare = gm.rare_gases.Copy()
			else
				for(var/id as anything in gm.rare_gases)
					total_rare[id] += gm.rare_gases[id]

	var/count = length(gas_list)
	if(!count)
		return

	// Calculate total heat capacity for temperature
	var/list/avg_core = NEW_CORE_MOLES
	var/list/idx_sh = GLOB.gas_idx_to_specific_heat
	var/total_hc = 0
	for(var/i in 1 to CORE_GAS_COUNT)
		avg_core[i] = total_core[i] / count
		total_hc += total_core[i] * idx_sh[i]
	var/list/avg_rare = null
	if(total_rare)
		avg_rare = list()
		var/list/gas_sh = GLOB.gas_data.specific_heats
		for(var/id as anything in total_rare)
			avg_rare[id] = total_rare[id] / count
			total_hc += total_rare[id] * gas_sh[id]

	var/avg_temp = TCMB
	if(total_hc > MINIMUM_HEAT_CAPACITY)
		avg_temp = max(total_thermal_energy / total_hc, TCMB)

	// Apply to all mixtures
	for(var/datum/gas_mixture/gm as anything in gas_list)
		if(!gm || gm._immutable || !gm.core_moles)
			continue
		var/list/gcm = gm.core_moles
		gcm[1] = avg_core[1]
		gcm[2] = avg_core[2]
		gcm[3] = avg_core[3]
		gcm[4] = avg_core[4]
		gcm[5] = avg_core[5]
		gcm[6] = avg_core[6]
		gcm[7] = avg_core[7]
		gcm[8] = avg_core[8]
		gcm[9] = avg_core[9]
		gcm[10] = avg_core[10]
		if(avg_rare)
			gm.rare_gases = avg_rare.Copy()
		else
			gm.rare_gases = null
		gm.temperature = avg_temp
		UPDATE_SIMPLE_AIR(gm)

/// Releases gas from src to output air. This means that it can not transfer air to gas mixture with higher pressure.
/proc/release_gas_to(datum/gas_mixture/input_air, datum/gas_mixture/output_air, target_pressure)
	var/output_starting_pressure = output_air.return_pressure()
	var/input_starting_pressure = input_air.return_pressure()

	if(output_starting_pressure >= min(target_pressure, input_starting_pressure - 10))
		//No need to pump gas if target is already reached or input pressure is too low
		//Need at least 10 KPa difference to overcome friction in the mechanism
		return FALSE

	//Calculate necessary moles to transfer using PV = nRT
	if((input_air.total_moles() > 0) && (input_air.return_temperature() > 0))
		var/pressure_delta = min(target_pressure - output_starting_pressure, (input_starting_pressure - output_starting_pressure) / 2)
		//Can not have a pressure delta that would cause output_pressure > input_pressure

		var/transfer_moles = pressure_delta * output_air.return_volume() / (input_air.return_temperature() * R_IDEAL_GAS_EQUATION)

		//Actually transfer the gas
		input_air.transfer_to(output_air, transfer_moles)

		return TRUE
	return FALSE

// =============================================
// HELPERS
// =============================================

/proc/gas_types()
	var/list/L = subtypesof(/datum/gas)
	for(var/gt in L)
		var/datum/gas/G = gt
		L[gt] = initial(G.specific_heat)
	return L

//Mathematical proofs:
/*
get_breath_partial_pressure(gas_pp) --> gas_pp/total_moles()*breath_pp = pp
get_true_breath_pressure(pp) --> gas_pp = pp/breath_pp*total_moles()
10/20*5 = 2.5
10 = 2.5/5*20
*/
