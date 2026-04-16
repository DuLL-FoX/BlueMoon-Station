// Gas mixture object pool — eliminates GC pressure from constant creation/destruction
// Uses a simple stack-based free list. Mixtures returned via qdel() are intercepted
// by gas_mixture/Destroy() and recycled instead of destroyed.

GLOBAL_LIST_INIT(gasmix_pool, list())
GLOBAL_VAR_INIT(gasmix_pool_count, 0)
// Stats for monitoring
GLOBAL_VAR_INIT(gasmix_pool_checkouts, 0)
GLOBAL_VAR_INIT(gasmix_pool_returns, 0)
GLOBAL_VAR_INIT(gasmix_pool_misses, 0)

/// Acquire a gas_mixture from the pool (or create new if pool empty).
/// The returned mixture has zeroed gas contents, TCMB temperature, and the specified volume.
/proc/gasmix_acquire(volume = CELL_VOLUME)
	GLOB.gasmix_pool_checkouts++
	var/datum/gas_mixture/gm
	if(GLOB.gasmix_pool_count > 0)
		gm = GLOB.gasmix_pool[GLOB.gasmix_pool_count]
		GLOB.gasmix_pool.len = GLOB.gasmix_pool_count - 1
		GLOB.gasmix_pool_count--
		gm._pooled = FALSE
		gm.volume = volume
	else
		GLOB.gasmix_pool_misses++
		gm = new /datum/gas_mixture(volume)
	return gm

/// Return a gas_mixture to the pool. Clears all data. Immutable mixtures are ignored.
/proc/gasmix_release(datum/gas_mixture/gm)
	if(!gm || gm._immutable || gm._pooled)
		return
	GLOB.gasmix_pool_returns++
	gm._pool_reset()
	if(GLOB.gasmix_pool_count < GASMIX_POOL_MAX)
		gm._pooled = TRUE
		GLOB.gasmix_pool_count++
		GLOB.gasmix_pool += gm
	else
		// Pool full — actually destroy
		gm._force_destroy = TRUE
		qdel(gm)

/// Pre-allocate gas mixtures into the pool. Called during SSair.Initialize().
/proc/gasmix_pool_preallocate(count = GASMIX_POOL_PREALLOCATE)
	for(var/i in 1 to count)
		var/datum/gas_mixture/gm = new
		gm._pool_reset()
		gm._pooled = TRUE
		GLOB.gasmix_pool_count++
		GLOB.gasmix_pool += gm
