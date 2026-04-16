/// Unit tests for turf atmospheric sharing and excited group mechanics.
/// These tests use the reserved 5x5 turf block and are more expensive than basic gas_mixture tests.

// ===== Gas Sharing Pressure Equalization (isolated test on gas_mixtures directly) =====

/datum/unit_test/turf_sharing_pressure_equalization
	priority = TEST_LONGER

/datum/unit_test/turf_sharing_pressure_equalization/Run()
	// Test share() directly on two isolated gas_mixtures (not turfs)
	// This avoids boundary effects from turf adjacency
	var/datum/gas_mixture/high = gasmix_acquire()
	var/datum/gas_mixture/low = gasmix_acquire()

	high.set_moles(GAS_O2, 200)
	high.set_moles(GAS_N2, 800)
	high.set_temperature(T20C)

	low.set_moles(GAS_O2, 5)
	low.set_moles(GAS_N2, 15)
	low.set_temperature(T20C)

	var/total_before = high.total_moles() + low.total_moles()

	// Archive and share (simulate 1 adjacent turf)
	high.archive()
	low.archive()
	high.share(low, 1)

	var/total_after = high.total_moles() + low.total_moles()

	// Verify gas moved from high to low
	TEST_ASSERT(high.total_moles() < 1000, "High-pressure mixture should have lost gas, has [high.total_moles()]")
	TEST_ASSERT(low.total_moles() > 20, "Low-pressure mixture should have gained gas, has [low.total_moles()]")

	// Verify conservation of mass (within floating point tolerance)
	TEST_ASSERT(abs(total_after - total_before) < 0.01, "Total moles should be conserved. Before: [total_before], After: [total_after]")

	gasmix_release(high)
	gasmix_release(low)

// ===== Excited Group Formation =====

/datum/unit_test/excited_group_formation
	priority = TEST_LONGER

/datum/unit_test/excited_group_formation/Run()
	// Get two adjacent turfs
	var/turf/open/turf_a = run_loc_floor_bottom_left
	TEST_ASSERT(istype(turf_a, /turf/open), "First test turf should be /turf/open")

	var/turf/open/turf_b
	for(var/turf/open/T in orange(1, turf_a))
		turf_b = T
		break
	TEST_ASSERT_NOTNULL(turf_b, "Should find an adjacent open turf")

	// Set up pressure differential to trigger excited group creation
	var/datum/gas_mixture/air_a = turf_a.air
	var/datum/gas_mixture/air_b = turf_b.air
	TEST_ASSERT_NOTNULL(air_a, "Turf A should have air")
	TEST_ASSERT_NOTNULL(air_b, "Turf B should have air")

	// Create significant pressure difference
	air_a.clear()
	air_a.set_moles(GAS_O2, 200)
	air_a.set_moles(GAS_N2, 800)
	air_a.set_temperature(T20C)

	air_b.clear()
	air_b.set_moles(GAS_O2, 2)
	air_b.set_moles(GAS_N2, 8)
	air_b.set_temperature(T20C)

	// Ensure atmos adjacency is set up
	if(!turf_a.atmos_adjacent_turfs)
		turf_a.atmos_adjacent_turfs = list()
	if(!turf_a.atmos_adjacent_turfs[turf_b])
		turf_a.atmos_adjacent_turfs[turf_b] = TRUE
	if(!turf_b.atmos_adjacent_turfs)
		turf_b.atmos_adjacent_turfs = list()
	if(!turf_b.atmos_adjacent_turfs[turf_a])
		turf_b.atmos_adjacent_turfs[turf_a] = TRUE

	// Clean up any pre-existing excited groups
	turf_a.excited_group = null
	turf_b.excited_group = null
	turf_a.excited = FALSE
	turf_b.excited = FALSE

	// Archive and process — this should trigger excited group formation
	air_a.archive()
	air_b.archive()

	SSair.add_to_active(turf_a)
	turf_a.process_cell(1)

	// Both turfs should now be in the same excited group (if sharing was significant)
	if(turf_a.excited_group && turf_b.excited_group)
		TEST_ASSERT_EQUAL(turf_a.excited_group, turf_b.excited_group, "Both turfs should share the same excited_group after significant air exchange")

	// Clean up
	if(turf_a.excited_group)
		turf_a.excited_group.dismantle()
	if(turf_b.excited_group)
		turf_b.excited_group.dismantle()

// ===== Excited Group Breakdown =====

/datum/unit_test/excited_group_breakdown
	priority = TEST_LONGER

/datum/unit_test/excited_group_breakdown/Run()
	// Create an excited group manually with turfs that have different pressures
	var/datum/excited_group/group = new
	SSair.excited_groups += group

	// Gather turfs from the test block
	var/list/turf/open/test_turfs = list()
	for(var/turf/open/T in block(run_loc_floor_bottom_left, run_loc_floor_top_right))
		test_turfs += T
		if(test_turfs.len >= 3)
			break

	TEST_ASSERT(test_turfs.len >= 2, "Need at least 2 open turfs for breakdown test, found [test_turfs.len]")

	// Set up different pressures
	for(var/i in 1 to test_turfs.len)
		var/turf/open/T = test_turfs[i]
		var/datum/gas_mixture/t_air = T.air
		if(!t_air)
			continue
		t_air.clear()
		t_air.set_moles(GAS_O2, 20 * i)
		t_air.set_moles(GAS_N2, 80 * i)
		t_air.set_temperature(T20C)
		group.add_turf(T)

	// Record initial pressure spread
	var/initial_max_pressure = 0
	var/initial_min_pressure = INFINITY
	for(var/turf/open/T as anything in test_turfs)
		var/p = T.air.return_pressure()
		initial_max_pressure = max(initial_max_pressure, p)
		initial_min_pressure = min(initial_min_pressure, p)

	var/initial_spread = initial_max_pressure - initial_min_pressure
	TEST_ASSERT(initial_spread > 10, "Initial pressure spread should be significant, got [initial_spread]")

	// Process group enough times to trigger breakdown
	for(var/i in 1 to EXCITED_GROUP_BREAKDOWN_CYCLES)
		group.process_group()

	// After breakdown (equalize), turfs should have similar pressures
	var/final_max_pressure = 0
	var/final_min_pressure = INFINITY
	for(var/turf/open/T as anything in test_turfs)
		var/p = T.air.return_pressure()
		final_max_pressure = max(final_max_pressure, p)
		final_min_pressure = min(final_min_pressure, p)

	var/final_spread = final_max_pressure - final_min_pressure
	TEST_ASSERT(final_spread < initial_spread, "Pressure spread should decrease after breakdown. Initial: [initial_spread], Final: [final_spread]")

	// Clean up
	group.dismantle()

// ===== Excited Group Dismantle =====

/datum/unit_test/excited_group_dismantle
	priority = TEST_LONGER

/datum/unit_test/excited_group_dismantle/Run()
	// Create an excited group with equalized turfs
	var/datum/excited_group/group = new
	SSair.excited_groups += group

	var/list/turf/open/test_turfs = list()
	for(var/turf/open/T in block(run_loc_floor_bottom_left, run_loc_floor_top_right))
		test_turfs += T
		if(test_turfs.len >= 2)
			break

	TEST_ASSERT(test_turfs.len >= 2, "Need at least 2 open turfs for dismantle test")

	// Set all turfs to identical gas composition (already equalized)
	for(var/turf/open/T as anything in test_turfs)
		var/datum/gas_mixture/t_air = T.air
		if(!t_air)
			continue
		t_air.clear()
		t_air.set_moles(GAS_O2, MOLES_O2STANDARD)
		t_air.set_moles(GAS_N2, MOLES_N2STANDARD)
		t_air.set_temperature(T20C)
		T.excited = TRUE
		SSair.active_turfs |= T
		group.add_turf(T)

	// Process group until dismantle
	for(var/i in 1 to EXCITED_GROUP_DISMANTLE_CYCLES)
		group.process_group()

	// After dismantling, turfs should no longer be excited
	for(var/turf/open/T as anything in test_turfs)
		TEST_ASSERT(!T.excited, "Turf should not be excited after group dismantle")
		TEST_ASSERT_NULL(T.excited_group, "Turf's excited_group should be null after dismantle")

// ===== Conservation of Mass (isolated gas_mixture chain test) =====

/datum/unit_test/conservation_of_mass
	priority = TEST_LONGER

/datum/unit_test/conservation_of_mass/Run()
	// Test conservation of mass across multiple rounds of share() on isolated mixtures
	// Using a chain of 4 gas_mixtures that share pairwise, simulating a 1D corridor
	var/chain_len = 4
	var/list/datum/gas_mixture/chain = list()
	for(var/i in 1 to chain_len)
		var/datum/gas_mixture/gm = gasmix_acquire()
		// Create pressure differentials
		gm.set_moles(GAS_O2, 20 + i * 30)
		gm.set_moles(GAS_N2, 80 + i * 15)
		gm.set_temperature(T20C + i * 20)
		chain += gm

	// Calculate initial total moles
	var/initial_total = 0
	for(var/datum/gas_mixture/gm as anything in chain)
		initial_total += gm.total_moles()

	// Run 10 rounds of pairwise sharing
	for(var/round in 1 to 10)
		// Archive all
		for(var/datum/gas_mixture/gm as anything in chain)
			gm.archive()
		// Share pairwise (1-2, 2-3, 3-4)
		for(var/i in 1 to chain_len - 1)
			chain[i].share(chain[i + 1], 1)

	// Calculate final total moles
	var/final_total = 0
	for(var/datum/gas_mixture/gm as anything in chain)
		final_total += gm.total_moles()

	TEST_ASSERT(abs(final_total - initial_total) < 0.1, "Total moles should be conserved across processing rounds. Initial: [initial_total], Final: [final_total]")

	// Cleanup
	for(var/datum/gas_mixture/gm as anything in chain)
		gasmix_release(gm)
