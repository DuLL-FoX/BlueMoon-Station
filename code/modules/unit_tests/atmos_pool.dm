/// Unit tests for gas_mixture object pool lifecycle.
/// Tests acquire/release cycling, qdel interception, pool overflow, state reset, and immutable bypass.

// ===== Acquire and Release =====

/datum/unit_test/pool_acquire_release

/datum/unit_test/pool_acquire_release/Run()
	// Acquire a mixture from the pool
	var/datum/gas_mixture/gm = gasmix_acquire(CELL_VOLUME)
	TEST_ASSERT_NOTNULL(gm, "gasmix_acquire() should return a non-null gas_mixture")

	// Verify it has the correct volume
	var/vol = gm.return_volume()
	TEST_ASSERT(abs(vol - CELL_VOLUME) < 0.01, "Acquired mixture should have volume [CELL_VOLUME], got [vol]")

	// Verify it starts clean (zeroed moles)
	TEST_ASSERT(gm.total_moles() < 0.01, "Acquired mixture should have ~0 total moles, got [gm.total_moles()]")

	// Note the reference
	var/first_ref = "\ref[gm]"

	// Release it back
	gasmix_release(gm)

	// Acquire again — should get the same datum back (recycled)
	var/datum/gas_mixture/gm2 = gasmix_acquire(CELL_VOLUME)
	TEST_ASSERT_NOTNULL(gm2, "Second gasmix_acquire() should return a non-null gas_mixture")

	var/second_ref = "\ref[gm2]"
	TEST_ASSERT_EQUAL(first_ref, second_ref, "Should receive the same recycled datum reference back from pool")

	// Verify the recycled datum has zeroed fields
	TEST_ASSERT(gm2.total_moles() < 0.01, "Recycled mixture should have zeroed moles, got [gm2.total_moles()]")

	gasmix_release(gm2)

// ===== qdel Interception =====

/datum/unit_test/pool_qdel_intercept

/datum/unit_test/pool_qdel_intercept/Run()
	// Create a gas_mixture normally
	var/datum/gas_mixture/gm = new(CELL_VOLUME)
	gm.set_moles(GAS_O2, 50)
	var/gm_ref = "\ref[gm]"

	// qdel it — Destroy() should intercept and pool it via QDEL_HINT_LETMELIVE
	qdel(gm)

	// The mixture should still exist (pooled, not actually destroyed)
	// Acquire from pool — we should get it back
	var/datum/gas_mixture/recycled = gasmix_acquire(CELL_VOLUME)
	TEST_ASSERT_NOTNULL(recycled, "Should be able to acquire from pool after qdel")

	// The recycled datum should have been reset (no stale O2 data)
	TEST_ASSERT(recycled.total_moles() < 0.01, "Recycled-via-qdel mixture should have zeroed moles, got [recycled.total_moles()]")

	gasmix_release(recycled)

// ===== Pool Overflow =====

/datum/unit_test/pool_overflow

/datum/unit_test/pool_overflow/Run()
	// Record current pool state
	var/initial_pool_count = GLOB.gasmix_pool_count

	// Create enough mixtures to fill the pool to max
	var/list/mixtures = list()
	var/to_create = GASMIX_POOL_MAX - initial_pool_count + 5 // 5 extras beyond max
	for(var/i in 1 to to_create)
		mixtures += new /datum/gas_mixture(CELL_VOLUME)

	// Release them all back into the pool
	for(var/datum/gas_mixture/gm as anything in mixtures)
		gasmix_release(gm)

	// Pool count should not exceed GASMIX_POOL_MAX
	TEST_ASSERT(GLOB.gasmix_pool_count <= GASMIX_POOL_MAX, "Pool count should not exceed GASMIX_POOL_MAX ([GASMIX_POOL_MAX]), got [GLOB.gasmix_pool_count]")

	// Drain the extras we added (clean up)
	var/to_drain = GLOB.gasmix_pool_count - initial_pool_count
	for(var/i in 1 to max(to_drain, 0))
		var/datum/gas_mixture/drain = gasmix_acquire(CELL_VOLUME)
		drain._force_destroy = TRUE
		qdel(drain)

// ===== Pool Reset State =====

/datum/unit_test/pool_reset_state

/datum/unit_test/pool_reset_state/Run()
	// Acquire a mixture from pool
	var/datum/gas_mixture/gm = gasmix_acquire(CELL_VOLUME)

	// Dirty it up
	gm.set_moles(GAS_O2, 500)
	gm.set_moles(GAS_N2, 300)
	gm.set_moles(GAS_PLASMA, 200)
	gm.set_temperature(5000)

	// Release back to pool
	gasmix_release(gm)

	// Acquire again — should get the same datum back, but fully clean
	var/datum/gas_mixture/clean = gasmix_acquire(CELL_VOLUME)
	TEST_ASSERT_NOTNULL(clean, "gasmix_acquire after release should return non-null")

	// Verify ALL fields are zeroed
	TEST_ASSERT(clean.total_moles() < 0.01, "Re-acquired mixture should have 0 moles, got [clean.total_moles()]")
	TEST_ASSERT(clean.get_moles(GAS_O2) <= 0, "Re-acquired O2 should be 0, got [clean.get_moles(GAS_O2)]")
	TEST_ASSERT(clean.get_moles(GAS_N2) <= 0, "Re-acquired N2 should be 0, got [clean.get_moles(GAS_N2)]")
	TEST_ASSERT(clean.get_moles(GAS_PLASMA) <= 0, "Re-acquired Plasma should be 0, got [clean.get_moles(GAS_PLASMA)]")

	// Temperature should be reset (TCMB or similar default)
	var/clean_temp = clean.return_temperature()
	TEST_ASSERT(clean_temp <= TCMB + 1, "Re-acquired temperature should be near TCMB, got [clean_temp]")

	gasmix_release(clean)

// ===== Immutable Bypass =====

/datum/unit_test/pool_immutable_bypass

/datum/unit_test/pool_immutable_bypass/Run()
	var/initial_pool_count = GLOB.gasmix_pool_count

	// Create an immutable gas_mixture
	var/datum/gas_mixture/gm = new(CELL_VOLUME)
	gm.set_moles(GAS_O2, 50)
	gm.mark_immutable()

	// Try gasmix_release on it — should be ignored (immutable mixtures don't pool)
	gasmix_release(gm)

	// Pool count should not have increased
	TEST_ASSERT_EQUAL(GLOB.gasmix_pool_count, initial_pool_count, "Pool count should not change when releasing immutable mixture")

	// qdel it — should actually destroy (not pool)
	qdel(gm)
