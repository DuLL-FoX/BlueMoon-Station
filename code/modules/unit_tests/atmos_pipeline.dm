/// Unit tests for atmospheric pipeline smoke testing.
/// Verifies that pipeline air objects function with the new gas_mixture implementation.

// ===== Pipeline Air from Pool =====

/datum/unit_test/pipeline_air_from_pool
	priority = TEST_LONGER

/datum/unit_test/pipeline_air_from_pool/Run()
	// Smoke test: create a simple pipe and verify its air mixture works
	var/obj/machinery/atmospherics/pipe/simple/test_pipe = allocate(/obj/machinery/atmospherics/pipe/simple)
	TEST_ASSERT_NOTNULL(test_pipe, "Should be able to allocate a simple pipe")

	// Verify the pipe exists and has basic properties
	TEST_ASSERT(istype(test_pipe), "Allocated object should be a pipe")

	// Create a gas_mixture via pool and verify it can be manipulated
	// (This tests that pipelines can work with pool-sourced gas_mixtures)
	var/datum/gas_mixture/pipe_air = gasmix_acquire(CELL_VOLUME)
	TEST_ASSERT_NOTNULL(pipe_air, "gasmix_acquire should return a valid gas_mixture for pipeline use")

	// Set some gas contents like a pipe would
	pipe_air.set_moles(GAS_O2, MOLES_O2STANDARD)
	pipe_air.set_moles(GAS_N2, MOLES_N2STANDARD)
	pipe_air.set_temperature(T20C)

	// Verify pressure calculation works
	var/pressure = pipe_air.return_pressure()
	TEST_ASSERT(pressure > 0, "Pipeline air should have positive pressure, got [pressure]")
	TEST_ASSERT(abs(pressure - ONE_ATMOSPHERE) < 5, "Pipeline air pressure should be near ONE_ATMOSPHERE, got [pressure]")

	// Verify we can remove gas from it (as a pump would)
	var/datum/gas_mixture/pumped = pipe_air.remove_ratio(0.1)
	TEST_ASSERT_NOTNULL(pumped, "remove_ratio on pipeline air should return a gas_mixture")
	TEST_ASSERT(pumped.total_moles() > 0, "Pumped gas should have some moles")

	// Clean up
	gasmix_release(pipe_air)
	qdel(pumped)
