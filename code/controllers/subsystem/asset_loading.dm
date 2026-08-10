/// Realizes deferred browser assets outside subsystem initialization.
///
/// Asset datums are still constructed by SSassets so type registration remains
/// deterministic. Expensive image composition is queued here and sliced across
/// ticks; get_asset_datum() can synchronously finish a requested datum when a UI
/// reaches it before the background queue does.
SUBSYSTEM_DEF(asset_loading)
	name = "Asset Loading"
	priority = FIRE_PRIORITY_ASSET_LOADING
	flags = SS_NO_INIT | SS_BACKGROUND
	runlevels = RUNLEVEL_LOBBY | RUNLEVELS_DEFAULT
	wait = 1
	var/list/datum/asset/generate_queue = list()
	var/assets_generating = 0
	var/last_queue_len = 0

/datum/controller/subsystem/asset_loading/fire(resumed)
	while(length(generate_queue))
		// FIFO preserves declaration/dependency order. In particular, a deferred
		// JSON catalog declared after its spritesheet must not force that sheet
		// through the synchronous first-use path.
		var/datum/asset/to_load = generate_queue[1]
		generate_queue.Cut(1, 2)
		to_load.generation_queued = FALSE
		last_queue_len = length(generate_queue) + 1
		var/generation_started = TICK_USAGE_REAL
		to_load.queued_generation()
		var/generation_ms = TICK_USAGE_TO_MS(generation_started)
		if(generation_ms >= 100)
			log_asset("Slow deferred asset dispatch: [to_load.type] blocked SSasset_loading for [round(generation_ms, 0.1)]ms (queue before dispatch: [last_queue_len])")
		if(MC_TICK_CHECK)
			return

	if(last_queue_len && !length(generate_queue) && !assets_generating)
		last_queue_len = 0
		rustg_iconforge_cleanup()

/datum/controller/subsystem/asset_loading/proc/queue_asset(datum/asset/queued_asset)
	if(queued_asset.generation_queued)
		return
	queued_asset.generation_queued = TRUE
	generate_queue += queued_asset

/datum/controller/subsystem/asset_loading/proc/dequeue_asset(datum/asset/queued_asset)
	if(!queued_asset.generation_queued)
		return
	queued_asset.generation_queued = FALSE
	generate_queue -= queued_asset
