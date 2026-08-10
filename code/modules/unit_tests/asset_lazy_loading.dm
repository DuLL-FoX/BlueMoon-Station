/datum/asset/json/lazy_loading_test
	_abstract = /datum/asset/json/lazy_loading_test
	name = "lazy_loading_test"
	var/generation_count = 0

/datum/asset/json/lazy_loading_test/generate()
	generation_count++
	return list("generation" = generation_count)

/datum/asset/spritesheet_batched/lazy_loading_test
	_abstract = /datum/asset/spritesheet_batched/lazy_loading_test
	name = "lazy_loading_test_sheet"
	sprites_per_shard = 2

/datum/asset/spritesheet_batched/lazy_loading_test/create_spritesheets()
	var/test_state = icon_states('icons/ui_icons/tgui/jobs.dmi')[1]
	insert_icon("first", uni_icon('icons/ui_icons/tgui/jobs.dmi', test_state, SOUTH))
	insert_icon("second", uni_icon('icons/ui_icons/tgui/jobs.dmi', test_state, SOUTH))
	insert_icon("third", uni_icon('icons/ui_icons/tgui/jobs.dmi', test_state, SOUTH))

/datum/asset/spritesheet_batched/single_flight_test
	_abstract = /datum/asset/spritesheet_batched/single_flight_test
	name = "single_flight_test_sheet"
	var/owner_runs = 0
	var/release_owner = FALSE

/datum/asset/spritesheet_batched/single_flight_test/create_spritesheets()
	insert_icon("test", uni_icon('icons/ui_icons/pills/pill1.png', ""))

/datum/asset/spritesheet_batched/single_flight_test/realize_spritesheets_owned(yield)
	owner_runs++
	UNTIL(release_owner)
	fully_generated = TRUE
	SSasset_loading.dequeue_asset(src)

/datum/asset/spritesheet_batched/single_flight_test/proc/release_owner_after_tick()
	stoplag(1)
	release_owner = TRUE

/datum/asset/spritesheet/lazy_order_test
	_abstract = /datum/asset/spritesheet/lazy_order_test
	name = "lazy_order_test_sheet"

/datum/asset/spritesheet/lazy_order_test/create_spritesheets()
	Insert("first", 'icons/ui_icons/pills/pill1.png')
	Insert("second", 'icons/ui_icons/pills/pill2.png')
	Insert("third", 'icons/ui_icons/pills/pill3.png')

/datum/asset/spritesheet/lazy_duplicate_test
	_abstract = /datum/asset/spritesheet/lazy_duplicate_test
	name = "lazy_duplicate_test_sheet"

/datum/asset/spritesheet/lazy_duplicate_test/create_spritesheets()
	Insert("duplicate", 'icons/ui_icons/pills/pill1.png')
	Insert("duplicate", 'icons/ui_icons/pills/pill2.png')

/datum/asset/spritesheet/lazy_runtime_icon_test
	_abstract = /datum/asset/spritesheet/lazy_runtime_icon_test
	name = "lazy_runtime_icon_test_sheet"

/datum/asset/spritesheet/lazy_runtime_icon_test/create_spritesheets()
	var/icon/temporary_icon = icon('icons/ui_icons/pills/pill1.png')
	temporary_icon.Blend("#80ff80", ICON_MULTIPLY)
	Insert("snapshot", temporary_icon)
	// This mutation must not affect the resource retained by deferred generation.
	temporary_icon.DrawBox("#000000", 1, 1, temporary_icon.Width(), temporary_icon.Height())

/datum/unit_test/asset_lazy_loading_contract/Run()
	var/json_type = /datum/asset/json/lazy_loading_test
	var/datum/asset/json/lazy_loading_test/lazy_json = load_asset_datum(json_type)
	TEST_ASSERT(!lazy_json.fully_generated, "load_asset_datum() eagerly generated a deferred JSON asset")
	TEST_ASSERT(lazy_json.generation_queued, "deferred JSON asset was not queued")

	var/datum/asset/json/lazy_loading_test/ready_json = get_asset_datum(json_type)
	TEST_ASSERT_EQUAL(ready_json, lazy_json, "get_asset_datum() replaced the registered datum")
	TEST_ASSERT(ready_json.fully_generated, "get_asset_datum() did not realize deferred JSON")
	TEST_ASSERT(!ready_json.generation_queued, "realized JSON remained in SSasset_loading")
	TEST_ASSERT_NOTNULL(SSassets.cache["lazy_loading_test.json"], "realized JSON was not mapped into SSassets.cache")

	var/old_url = ready_json.get_url_mappings()["lazy_loading_test.json"]
	ready_json.regenerate()
	var/new_url = ready_json.get_url_mappings()["lazy_loading_test.json"]
	TEST_ASSERT_NOTEQUAL(old_url, new_url, "regenerate() retained the old content-addressed JSON mapping")
	TEST_ASSERT_EQUAL(ready_json.generation_count, 2, "regenerate() did not run exactly one new generation")

	ready_json.unregister()
	TEST_ASSERT_NULL(SSassets.cache["lazy_loading_test.json"], "unregister() left JSON in SSassets.cache")
	GLOB.asset_datums.Remove(json_type)
	qdel(ready_json)

/datum/unit_test/asset_batched_smart_cache/Run()
	var/sheet_type = /datum/asset/spritesheet_batched/lazy_loading_test
	var/meta_path = "[SPRITESHEET_CACHE_DIR]cache_batched.lazy_loading_test_sheet.json"
	fdel(meta_path)

	var/datum/asset/spritesheet_batched/lazy_loading_test/lazy_sheet = load_asset_datum(sheet_type)
	TEST_ASSERT(!lazy_sheet.fully_generated, "load_asset_datum() eagerly ran IconForge")
	var/datum/asset/spritesheet_batched/lazy_loading_test/ready_sheet = get_asset_datum(sheet_type)
	TEST_ASSERT(ready_sheet.fully_generated, "get_asset_datum() did not finish IconForge generation")
	TEST_ASSERT(fexists(meta_path), "IconForge smart-cache metadata was not written")
	TEST_ASSERT(length(ready_sheet.get_url_mappings()) > 1, "batched spritesheet did not expose CSS and PNG mappings")
	TEST_ASSERT_EQUAL(length(ready_sheet.sheet_files), 2, "batched spritesheet did not split at sprites_per_shard")
	TEST_ASSERT_NOTEQUAL(ready_sheet.sprites["first"]["file"], ready_sheet.sprites["third"]["file"], "sprites from separate shards point at the same PNG")
	var/list/first_sprites = ready_sheet.sprites.Copy()

	ready_sheet.unregister()
	GLOB.asset_datums.Remove(sheet_type)
	qdel(ready_sheet)

	var/datum/asset/spritesheet_batched/lazy_loading_test/cached_sheet = new sheet_type()
	cached_sheet.ensure_ready()
	TEST_ASSERT(cached_sheet.fully_generated, "second batched spritesheet did not become ready")
	TEST_ASSERT(!cached_sheet.cache_result, "second batched spritesheet missed a valid smart cache")
	TEST_ASSERT_EQUAL(length(cached_sheet.sprites), length(first_sprites), "smart-cache sprite mapping changed on reload")

	cached_sheet.unregister()
	GLOB.asset_datums.Remove(sheet_type)
	qdel(cached_sheet)

	// A changed partition must invalidate rather than indexing past the cached
	// shard list, even though its sprite inputs are otherwise identical.
	var/datum/asset/spritesheet_batched/lazy_loading_test/repartitioned_sheet = new sheet_type()
	repartitioned_sheet.sprites_per_shard = 1
	repartitioned_sheet.ensure_ready()
	TEST_ASSERT_EQUAL(length(repartitioned_sheet.sheet_files), 3, "changed shard size did not rebuild the batched spritesheet")

	repartitioned_sheet.unregister()
	for(var/png_name in repartitioned_sheet.sheet_files)
		fdel("[SPRITESHEET_CACHE_DIR][png_name]")
	fdel("[SPRITESHEET_CACHE_DIR]spritesheet_lazy_loading_test_sheet.css")
	fdel(meta_path)
	GLOB.asset_datums.Remove(sheet_type)
	qdel(repartitioned_sheet)

/// DMI-backed legacy sheets cannot yield safely while composing a datum. Only
/// the small static-PNG maps may remain on that compatibility path.
/datum/unit_test/asset_production_dmi_spritesheets_use_batched_layout/Run()
	for(var/sheet_type in subtypesof(/datum/asset/spritesheet))
		var/datum/asset/sheet = sheet_type
		if(sheet_type == initial(sheet._abstract))
			continue
		if(ispath(sheet_type, /datum/asset/spritesheet/simple))
			continue
		TEST_FAIL("DMI-backed production spritesheet [sheet_type] still uses the blocking legacy compositor")

/datum/unit_test/asset_batched_single_flight/Run()
	var/sheet_type = /datum/asset/spritesheet_batched/single_flight_test
	var/datum/asset/spritesheet_batched/single_flight_test/sheet = load_asset_datum(sheet_type)
	sheet.queued_generation()
	UNTIL(sheet.generation_in_progress)
	INVOKE_ASYNC(sheet, TYPE_PROC_REF(/datum/asset/spritesheet_batched/single_flight_test, release_owner_after_tick))
	sheet.ensure_ready()

	TEST_ASSERT(sheet.fully_generated, "synchronous waiter returned before the queued owner completed")
	TEST_ASSERT_EQUAL(sheet.owner_runs, 1, "queued generation and ensure_ready() both became IconForge job owners")
	TEST_ASSERT(!sheet.generation_in_progress, "single-flight owner remained locked after completion")
	TEST_ASSERT_NULL(sheet.generation_error, "successful single-flight generation retained an error")

	sheet.unregister()
	GLOB.asset_datums.Remove(sheet_type)
	qdel(sheet)

/datum/unit_test/asset_lazy_legacy_order/Run()
	var/sheet_type = /datum/asset/spritesheet/lazy_order_test
	var/datum/asset/spritesheet/lazy_order_test/lazy_sheet = load_asset_datum(sheet_type)
	TEST_ASSERT(!lazy_sheet.fully_generated, "legacy spritesheet was realized by load_asset_datum()")
	TEST_ASSERT_EQUAL(lazy_sheet.generation_index, 1, "legacy spritesheet queue did not start at its first insertion")
	var/datum/asset/spritesheet/lazy_order_test/ready_sheet = get_asset_datum(sheet_type)
	TEST_ASSERT_EQUAL(ready_sheet.sprites["first"][2], 0, "deferred realization reversed the first sprite")
	TEST_ASSERT_EQUAL(ready_sheet.sprites["second"][2], 1, "deferred realization changed the second sprite position")
	TEST_ASSERT_EQUAL(ready_sheet.sprites["third"][2], 2, "deferred realization reversed the last sprite")
	TEST_ASSERT(!length(ready_sheet.to_generate), "legacy spritesheet retained realized Insert arguments")

	ready_sheet.unregister()
	for(var/size_id in ready_sheet.sizes)
		fdel("[SPRITESHEET_CACHE_DIR]lazy_order_test_sheet_[size_id].png")
	fdel("[SPRITESHEET_CACHE_DIR]spritesheet_lazy_order_test_sheet.css")
	fdel("[SPRITESHEET_CACHE_DIR]cache.lazy_order_test_sheet.json")
	GLOB.asset_datums.Remove(sheet_type)
	qdel(ready_sheet)

/datum/unit_test/asset_lazy_duplicate_guard/Run()
	var/sheet_type = /datum/asset/spritesheet/lazy_duplicate_test
	var/caught_duplicate = FALSE
	try
		load_asset_datum(sheet_type)
	catch(var/exception/error)
		caught_duplicate = findtext(error.name, "duplicate sprite")
	TEST_ASSERT(caught_duplicate, "deferred Insert() no longer rejected a duplicate sprite name at registration")
	var/datum/asset/partial_sheet = GLOB.asset_datums[sheet_type]
	GLOB.asset_datums.Remove(sheet_type)
	if(partial_sheet)
		qdel(partial_sheet)

/datum/unit_test/asset_lazy_runtime_icon_snapshot/Run()
	var/sheet_type = /datum/asset/spritesheet/lazy_runtime_icon_test
	var/datum/asset/spritesheet/lazy_runtime_icon_test/lazy_sheet = load_asset_datum(sheet_type)
	TEST_ASSERT_EQUAL(length(lazy_sheet.to_generate), 1, "runtime icon Insert() was not queued exactly once")
	var/list/stored_args = lazy_sheet.to_generate[1]
	TEST_ASSERT(isfile(stored_args[2]), "deferred spritesheet retained a mutable runtime /icon instead of a resource snapshot")
	TEST_ASSERT(stored_args[7], "runtime icon snapshot was not marked as already modified")

	lazy_sheet.ensure_ready()
	TEST_ASSERT(lazy_sheet.fully_generated, "deferred runtime icon snapshot could not be realized")
	TEST_ASSERT_NOTNULL(lazy_sheet.sprites["snapshot"], "runtime icon snapshot is absent from the realized sheet")

	lazy_sheet.unregister()
	for(var/size_id in lazy_sheet.sizes)
		fdel("[SPRITESHEET_CACHE_DIR]lazy_runtime_icon_test_sheet_[size_id].png")
	fdel("[SPRITESHEET_CACHE_DIR]spritesheet_lazy_runtime_icon_test_sheet.css")
	fdel("[SPRITESHEET_CACHE_DIR]cache.lazy_runtime_icon_test_sheet.json")
	GLOB.asset_datums.Remove(sheet_type)
	qdel(lazy_sheet)
