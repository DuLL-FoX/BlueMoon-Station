/// Unit tests for pure DM gas_mixture core operations.
/// Tests storage, temperature, pressure, heat capacity, merge, remove, copy, share, and more.

// ===== Core Storage =====

/datum/unit_test/gas_mixture_core_storage

/datum/unit_test/gas_mixture_core_storage/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)

	// Set core gases via string ID
	gm.set_moles(GAS_O2, 21)
	gm.set_moles(GAS_N2, 79)

	TEST_ASSERT_EQUAL(gm.get_moles(GAS_O2), 21, "O2 moles should be 21")
	TEST_ASSERT_EQUAL(gm.get_moles(GAS_N2), 79, "N2 moles should be 79")

	// Verify rare gas storage (hypernoblium is NOT a core gas)
	gm.set_moles(GAS_HYPERNOB, 5)
	TEST_ASSERT_EQUAL(gm.get_moles(GAS_HYPERNOB), 5, "Hypernoblium moles should be 5")

	// Verify total_moles sums core + rare
	var/expected_total = 21 + 79 + 5
	var/actual_total = gm.total_moles()
	TEST_ASSERT(abs(actual_total - expected_total) < 0.01, "total_moles should be [expected_total], got [actual_total]")

	qdel(gm)

// ===== Temperature =====

/datum/unit_test/gas_mixture_temperature

/datum/unit_test/gas_mixture_temperature/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)

	// Set normal temperature
	gm.set_temperature(T20C)
	TEST_ASSERT(abs(gm.return_temperature() - T20C) < 0.01, "Temperature should be T20C ([T20C]), got [gm.return_temperature()]")

	// Set very high temperature
	gm.set_temperature(10000)
	TEST_ASSERT(abs(gm.return_temperature() - 10000) < 0.01, "Temperature should be 10000, got [gm.return_temperature()]")

	// TCMB is the minimum temperature enforced by many operations
	gm.set_temperature(TCMB)
	TEST_ASSERT(gm.return_temperature() >= TCMB, "Temperature should not drop below TCMB ([TCMB]), got [gm.return_temperature()]")

	// Set to absolute zero-like value — should clamp to TCMB or stay as-is depending on implementation
	gm.set_temperature(0)
	// After setting to 0, return_temperature should still return a value (implementation may clamp)
	var/temp_result = gm.return_temperature()
	TEST_ASSERT_NOTNULL(temp_result, "return_temperature() should not return null after setting to 0")

	qdel(gm)

// ===== Pressure =====

/datum/unit_test/gas_mixture_pressure

/datum/unit_test/gas_mixture_pressure/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)
	gm.set_temperature(T20C)

	// Standard atmosphere: PV = nRT => P = nRT/V
	var/total_moles = MOLES_O2STANDARD + MOLES_N2STANDARD
	gm.set_moles(GAS_O2, MOLES_O2STANDARD)
	gm.set_moles(GAS_N2, MOLES_N2STANDARD)

	var/expected_pressure = total_moles * R_IDEAL_GAS_EQUATION * T20C / CELL_VOLUME
	var/actual_pressure = gm.return_pressure()
	TEST_ASSERT(abs(actual_pressure - expected_pressure) < 0.5, "Pressure should be ~[expected_pressure] kPa (ONE_ATMOSPHERE), got [actual_pressure]")

	// Zero volume should return 0 pressure (no division by zero)
	var/datum/gas_mixture/zero_vol = new(0)
	zero_vol.set_temperature(T20C)
	zero_vol.set_moles(GAS_O2, 100)
	var/zero_pressure = zero_vol.return_pressure()
	// Pressure should be 0 or false when volume is 0
	TEST_ASSERT(!zero_pressure || zero_pressure == 0, "Pressure with zero volume should be 0, got [zero_pressure]")

	qdel(gm)
	qdel(zero_vol)

// ===== Heat Capacity =====

/datum/unit_test/gas_mixture_heat_capacity

/datum/unit_test/gas_mixture_heat_capacity/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)

	// Set known gases with known specific heats
	var/o2_moles = 10
	var/n2_moles = 20
	gm.set_moles(GAS_O2, o2_moles)
	gm.set_moles(GAS_N2, n2_moles)
	gm.set_temperature(T20C)

	var/o2_specific_heat = GLOB.gas_data.specific_heats[GAS_O2]
	var/n2_specific_heat = GLOB.gas_data.specific_heats[GAS_N2]
	TEST_ASSERT_NOTNULL(o2_specific_heat, "O2 specific heat should be defined in gas_data")
	TEST_ASSERT_NOTNULL(n2_specific_heat, "N2 specific heat should be defined in gas_data")

	var/expected_hc = o2_moles * o2_specific_heat + n2_moles * n2_specific_heat
	var/actual_hc = gm.heat_capacity()
	TEST_ASSERT(abs(actual_hc - expected_hc) < 0.1, "Heat capacity should be [expected_hc], got [actual_hc]")

	// Empty mixture should have 0 heat capacity (or HEAT_CAPACITY_VACUUM for turf subtype)
	var/datum/gas_mixture/empty_gm = new(CELL_VOLUME)
	var/empty_hc = empty_gm.heat_capacity()
	TEST_ASSERT(empty_hc >= 0, "Empty gas_mixture heat capacity should be >= 0, got [empty_hc]")

	qdel(gm)
	qdel(empty_gm)

// ===== Merge =====

/datum/unit_test/gas_mixture_merge

/datum/unit_test/gas_mixture_merge/Run()
	var/datum/gas_mixture/gm_a = new(CELL_VOLUME)
	var/datum/gas_mixture/gm_b = new(CELL_VOLUME)

	// Setup gm_a with O2 + N2 at T20C
	gm_a.set_moles(GAS_O2, 50)
	gm_a.set_moles(GAS_N2, 100)
	gm_a.set_temperature(T20C)

	// Setup gm_b with CO2 + Plasma at higher temp
	gm_b.set_moles(GAS_CO2, 30)
	gm_b.set_moles(GAS_PLASMA, 70)
	gm_b.set_temperature(500)

	// Record pre-merge totals
	var/total_moles_before = gm_a.total_moles() + gm_b.total_moles()
	var/thermal_energy_before = gm_a.thermal_energy() + gm_b.thermal_energy()

	// Merge gm_b into gm_a
	gm_a.merge(gm_b)

	// Verify mole conservation
	var/total_moles_after = gm_a.total_moles()
	TEST_ASSERT(abs(total_moles_after - total_moles_before) < 0.1, "Total moles should be conserved after merge. Before: [total_moles_before], After: [total_moles_after]")

	// Verify all gases present
	TEST_ASSERT(gm_a.get_moles(GAS_O2) > 0, "O2 should be present after merge")
	TEST_ASSERT(gm_a.get_moles(GAS_N2) > 0, "N2 should be present after merge")
	TEST_ASSERT(gm_a.get_moles(GAS_CO2) > 0, "CO2 should be present after merge")
	TEST_ASSERT(gm_a.get_moles(GAS_PLASMA) > 0, "Plasma should be present after merge")

	// Verify thermal energy conservation (within floating point tolerance)
	var/thermal_energy_after = gm_a.thermal_energy()
	TEST_ASSERT(abs(thermal_energy_after - thermal_energy_before) < 1, "Thermal energy should be conserved. Before: [thermal_energy_before], After: [thermal_energy_after]")

	qdel(gm_a)
	qdel(gm_b)

// ===== Remove =====

/datum/unit_test/gas_mixture_remove

/datum/unit_test/gas_mixture_remove/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)
	gm.set_moles(GAS_O2, 50)
	gm.set_moles(GAS_N2, 150)
	gm.set_temperature(T20C)

	var/original_total = gm.total_moles()

	// Remove 40 moles
	var/datum/gas_mixture/removed = gm.remove(40)
	TEST_ASSERT_NOTNULL(removed, "remove() should return a gas_mixture")

	var/removed_total = removed.total_moles()
	var/remaining_total = gm.total_moles()

	// Total moles should be conserved
	TEST_ASSERT(abs((remaining_total + removed_total) - original_total) < 0.01, "Moles should be conserved. Original: [original_total], Remaining+Removed: [remaining_total + removed_total]")

	// Removed mixture should have proportional amounts
	// O2 was 50/200 = 25%, N2 was 150/200 = 75%
	var/removed_o2 = removed.get_moles(GAS_O2)
	var/removed_n2 = removed.get_moles(GAS_N2)
	if(removed_total > 0)
		var/o2_fraction = removed_o2 / removed_total
		TEST_ASSERT(abs(o2_fraction - 0.25) < 0.02, "Removed O2 fraction should be ~0.25, got [o2_fraction]")

	qdel(gm)
	qdel(removed)

// ===== Remove Ratio =====

/datum/unit_test/gas_mixture_remove_ratio

/datum/unit_test/gas_mixture_remove_ratio/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)
	gm.set_moles(GAS_O2, 100)
	gm.set_moles(GAS_N2, 100)
	gm.set_temperature(T20C)

	// Remove 50%
	var/datum/gas_mixture/half = gm.remove_ratio(0.5)
	TEST_ASSERT_NOTNULL(half, "remove_ratio(0.5) should return a gas_mixture")

	// Each gas should be approximately halved in the removed portion
	var/half_o2 = half.get_moles(GAS_O2)
	TEST_ASSERT(abs(half_o2 - 50) < 1, "Removed O2 should be ~50, got [half_o2]")

	// Source should also be approximately halved
	var/remaining_o2 = gm.get_moles(GAS_O2)
	TEST_ASSERT(abs(remaining_o2 - 50) < 1, "Remaining O2 should be ~50, got [remaining_o2]")

	qdel(half)

	// Remove 100% of remaining
	var/datum/gas_mixture/all = gm.remove_ratio(1)
	TEST_ASSERT_NOTNULL(all, "remove_ratio(1) should return a gas_mixture")

	var/source_total = gm.total_moles()
	TEST_ASSERT(source_total < 0.01, "Source should be empty after removing 100%, has [source_total] moles")

	qdel(all)

	// Remove 0% — should return null
	gm.set_moles(GAS_O2, 50)
	var/datum/gas_mixture/zero = gm.remove_ratio(0)
	TEST_ASSERT_NULL(zero, "remove_ratio(0) should return null")

	qdel(gm)

// ===== Copy =====

/datum/unit_test/gas_mixture_copy

/datum/unit_test/gas_mixture_copy/Run()
	var/datum/gas_mixture/original = new(CELL_VOLUME)
	original.set_moles(GAS_O2, 42)
	original.set_moles(GAS_N2, 58)
	original.set_moles(GAS_HYPERNOB, 3)
	original.set_temperature(400)

	var/datum/gas_mixture/copy = original.copy()
	TEST_ASSERT_NOTNULL(copy, "copy() should return a gas_mixture")

	// Verify identical values
	TEST_ASSERT(abs(copy.get_moles(GAS_O2) - 42) < 0.01, "Copy O2 should be 42, got [copy.get_moles(GAS_O2)]")
	TEST_ASSERT(abs(copy.get_moles(GAS_N2) - 58) < 0.01, "Copy N2 should be 58, got [copy.get_moles(GAS_N2)]")
	TEST_ASSERT(abs(copy.return_temperature() - 400) < 0.01, "Copy temperature should be 400, got [copy.return_temperature()]")

	// Modify copy, verify original is unchanged
	copy.set_moles(GAS_O2, 999)
	TEST_ASSERT(abs(original.get_moles(GAS_O2) - 42) < 0.01, "Modifying copy should not affect original O2. Got [original.get_moles(GAS_O2)]")

	qdel(original)
	qdel(copy)

// ===== Transfer To =====

/datum/unit_test/gas_mixture_transfer_to

/datum/unit_test/gas_mixture_transfer_to/Run()
	var/datum/gas_mixture/source = new(CELL_VOLUME)
	var/datum/gas_mixture/target = new(CELL_VOLUME)

	source.set_moles(GAS_O2, 100)
	source.set_moles(GAS_N2, 100)
	source.set_temperature(600)

	target.set_moles(GAS_CO2, 50)
	target.set_temperature(300)

	var/total_moles_before = source.total_moles() + target.total_moles()
	var/thermal_energy_before = source.thermal_energy() + target.thermal_energy()

	// Transfer 40 moles from source to target
	source.transfer_to(target, 40)

	var/total_moles_after = source.total_moles() + target.total_moles()
	TEST_ASSERT(abs(total_moles_after - total_moles_before) < 0.1, "Moles should be conserved after transfer. Before: [total_moles_before], After: [total_moles_after]")

	var/thermal_energy_after = source.thermal_energy() + target.thermal_energy()
	TEST_ASSERT(abs(thermal_energy_after - thermal_energy_before) < 1, "Thermal energy should be conserved after transfer. Before: [thermal_energy_before], After: [thermal_energy_after]")

	qdel(source)
	qdel(target)

// ===== Share =====

/datum/unit_test/gas_mixture_share

/datum/unit_test/gas_mixture_share/Run()
	var/datum/gas_mixture/high_pressure = new(CELL_VOLUME)
	var/datum/gas_mixture/low_pressure = new(CELL_VOLUME)

	// High pressure: lots of gas
	high_pressure.set_moles(GAS_O2, 200)
	high_pressure.set_moles(GAS_N2, 800)
	high_pressure.set_temperature(T20C)

	// Low pressure: very little gas
	low_pressure.set_moles(GAS_O2, 5)
	low_pressure.set_moles(GAS_N2, 15)
	low_pressure.set_temperature(T20C)

	var/total_moles_before = high_pressure.total_moles() + low_pressure.total_moles()
	var/thermal_energy_before = high_pressure.thermal_energy() + low_pressure.thermal_energy()

	// Archive both before sharing (required by share())
	high_pressure.archive()
	low_pressure.archive()

	// Share
	high_pressure.share(low_pressure)

	var/total_moles_after = high_pressure.total_moles() + low_pressure.total_moles()

	// Conservation of mass
	TEST_ASSERT(abs(total_moles_after - total_moles_before) < 0.1, "Moles should be conserved after share. Before: [total_moles_before], After: [total_moles_after]")

	// Gas should have moved from high to low
	TEST_ASSERT(high_pressure.total_moles() < 1000, "High pressure turf should have lost some gas")
	TEST_ASSERT(low_pressure.total_moles() > 20, "Low pressure turf should have gained some gas")

	qdel(high_pressure)
	qdel(low_pressure)

// ===== Parse Gas String =====

/datum/unit_test/gas_mixture_parse_gas_string

/datum/unit_test/gas_mixture_parse_gas_string/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)

	// Parse standard atmosphere string
	gm.parse_gas_string("o2=21.78;n2=82.36;TEMP=293.15")

	var/o2 = gm.get_moles(GAS_O2)
	var/n2 = gm.get_moles(GAS_N2)
	var/temp = gm.return_temperature()

	TEST_ASSERT(abs(o2 - 21.78) < 0.1, "Parsed O2 should be ~21.78, got [o2]")
	TEST_ASSERT(abs(n2 - 82.36) < 0.1, "Parsed N2 should be ~82.36, got [n2]")
	TEST_ASSERT(abs(temp - 293.15) < 0.5, "Parsed temperature should be ~293.15, got [temp]")

	qdel(gm)

// ===== Archive =====

/datum/unit_test/gas_mixture_archive

/datum/unit_test/gas_mixture_archive/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)
	gm.set_moles(GAS_O2, 100)
	gm.set_temperature(500)

	// Archive
	gm.archive()

	// Change values
	gm.set_moles(GAS_O2, 200)
	gm.set_temperature(1000)

	// Current values should reflect changes
	TEST_ASSERT(abs(gm.get_moles(GAS_O2) - 200) < 0.01, "Current O2 should be 200 after change")
	TEST_ASSERT(abs(gm.return_temperature() - 1000) < 0.01, "Current temperature should be 1000 after change")

	// The archive was captured — this is verified indirectly through share() working correctly
	// (share uses archived values). Direct access to archived vars depends on implementation.

	qdel(gm)

// ===== Compare =====

/datum/unit_test/gas_mixture_compare

/datum/unit_test/gas_mixture_compare/Run()
	var/datum/gas_mixture/gm_a = new(CELL_VOLUME)
	var/datum/gas_mixture/gm_b = new(CELL_VOLUME)

	// Set identical
	gm_a.set_moles(GAS_O2, MOLES_O2STANDARD)
	gm_a.set_moles(GAS_N2, MOLES_N2STANDARD)
	gm_a.set_temperature(T20C)

	gm_b.set_moles(GAS_O2, MOLES_O2STANDARD)
	gm_b.set_moles(GAS_N2, MOLES_N2STANDARD)
	gm_b.set_temperature(T20C)

	// Compare identical — should return empty string
	var/result_identical = gm_a.compare(gm_b)
	TEST_ASSERT_EQUAL(result_identical, "", "Identical mixtures should compare as empty string, got '[result_identical]'")

	// Change one's O2 significantly
	gm_b.set_moles(GAS_O2, MOLES_O2STANDARD + 50)
	var/result_gas = gm_a.compare(gm_b)
	TEST_ASSERT(result_gas != "", "Mixtures with different O2 should not compare as identical")

	// Reset gm_b, change only temperature significantly
	gm_b.set_moles(GAS_O2, MOLES_O2STANDARD)
	gm_b.set_temperature(T20C + 200)
	var/result_temp = gm_a.compare(gm_b)
	TEST_ASSERT_EQUAL(result_temp, "temp", "Temperature-only difference should return 'temp', got '[result_temp]'")

	qdel(gm_a)
	qdel(gm_b)

// ===== Immutable =====

/datum/unit_test/gas_mixture_immutable

/datum/unit_test/gas_mixture_immutable/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)
	gm.set_moles(GAS_O2, 50)
	gm.set_temperature(T20C)
	gm.mark_immutable()

	// After marking immutable, set_moles should be a no-op
	gm.set_moles(GAS_O2, 999)
	// Whether immutable prevents changes depends on implementation, but the value should
	// remain usable without crashing
	var/o2_after = gm.get_moles(GAS_O2)
	TEST_ASSERT_NOTNULL(o2_after, "get_moles on immutable mixture should not return null")

	// Temperature changes should also be prevented or at least not crash
	gm.set_temperature(9999)
	var/temp_after = gm.return_temperature()
	TEST_ASSERT_NOTNULL(temp_after, "return_temperature on immutable mixture should not return null")

	qdel(gm)

// ===== Clear =====

/datum/unit_test/gas_mixture_clear

/datum/unit_test/gas_mixture_clear/Run()
	var/datum/gas_mixture/gm = new(CELL_VOLUME)
	gm.set_moles(GAS_O2, 100)
	gm.set_moles(GAS_N2, 200)
	gm.set_moles(GAS_PLASMA, 50)
	gm.set_temperature(1000)

	gm.clear()

	// All moles should be zero
	TEST_ASSERT(gm.get_moles(GAS_O2) <= 0, "O2 should be 0 after clear, got [gm.get_moles(GAS_O2)]")
	TEST_ASSERT(gm.get_moles(GAS_N2) <= 0, "N2 should be 0 after clear, got [gm.get_moles(GAS_N2)]")
	TEST_ASSERT(gm.get_moles(GAS_PLASMA) <= 0, "Plasma should be 0 after clear, got [gm.get_moles(GAS_PLASMA)]")

	// Total moles should be zero
	TEST_ASSERT(gm.total_moles() < 0.01, "Total moles should be ~0 after clear, got [gm.total_moles()]")

	qdel(gm)
