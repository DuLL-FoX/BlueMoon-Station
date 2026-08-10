#define BATCHED_SPR_SIZE "size_id"
#define BATCHED_SPR_IDX "position"
#define BATCHED_SPR_FILE "file"
#define BATCHED_CACHE_INVALID TRUE
#define BATCHED_CACHE_VALID FALSE
/// Bump when the IconForge input or generated CSS layout changes.
#define BATCHED_SPRITESHEET_VERSION 3
#define BATCHED_DEFAULT_SPRITES_PER_SHARD 256
#define BATCHED_MAX_SHEET_WIDTH 16384

/// Spritesheet implementation backed by rust-g IconForge.
///
/// create_spritesheets() only records file/state/transform descriptions. The
/// actual PNG composition is asynchronous through SSasset_loading unless a UI
/// requests the datum first via get_asset_datum().
/datum/asset/spritesheet_batched
	_abstract = /datum/asset/spritesheet_batched
	var/name
	var/list/sizes = list()
	var/list/sprites = list()
	/// Output PNG names. IconForge itself emits one unbounded horizontal row, so
	/// large sheets are split into browser-safe shards before generation.
	var/list/sheet_files = list()
	var/list/entries = list()
	var/entries_json
	var/sprites_per_shard = BATCHED_DEFAULT_SPRITES_PER_SHARD
	var/fully_generated = FALSE
	var/load_immediately = FALSE
	var/ignore_dir_errors = FALSE
	var/job_id
	var/cache_job_id
	var/cache_data
	var/list/cache_sizes_data
	var/list/cache_sprites_data
	var/list/cache_sheet_files_data
	/// One IconForge smart-cache record per generated shard. IconForge hashes the
	/// parsed sprite input, so a hash computed directly from the combined JSON is
	/// not interchangeable with the per-job sprites_hash it returns.
	var/list/cache_shards_data
	var/cache_result
	/// Single-flight guard: rust-g job results are consumptive and must have one poller.
	var/generation_in_progress = FALSE
	/// Preserves an owner failure for synchronous waiters without polling its job again.
	var/generation_error

/datum/asset/spritesheet_batched/proc/cache_meta_path()
	return "[SPRITESHEET_CACHE_DIR]cache_batched.[name].json"

/datum/asset/spritesheet_batched/proc/should_load_immediately()
#ifdef DO_NOT_DEFER_ASSETS
	return TRUE
#else
	return load_immediately || early
#endif

/datum/asset/spritesheet_batched/proc/insert_icon(sprite_name, datum/universal_icon/entry)
	if(!istext(sprite_name) || !length(sprite_name))
		CRASH("Invalid sprite name [sprite_name] for [type]")
	if(!istype(entry))
		CRASH("Invalid universal icon [entry] for [type]")
	if(entries[sprite_name])
		CRASH("Duplicate sprite [sprite_name] in [type]")
	entries[sprite_name] = entry.to_list()

/datum/asset/spritesheet_batched/proc/insert_all_icons(prefix, icon/icon_file, list/directions, prefix_with_dirs = TRUE)
	if(length(prefix))
		prefix = "[prefix]-"
	if(!directions)
		directions = list(SOUTH)
	for(var/icon_state_name in icon_states(icon_file))
		for(var/direction in directions)
			var/direction_prefix = length(directions) > 1 && prefix_with_dirs ? "[dir2text(direction)]-" : ""
			insert_icon("[prefix][direction_prefix][icon_state_name]", uni_icon(icon_file, icon_state_name, direction))

/datum/asset/spritesheet_batched/register()
	if(!name)
		CRASH("Batched spritesheet [type] cannot register without a name")
	create_spritesheets()
	if(should_load_immediately())
		realize_spritesheets(yield = FALSE)
	else
		SSasset_loading.queue_asset(src)

/// Override to populate entries with insert_icon()/insert_all_icons().
/datum/asset/spritesheet_batched/proc/create_spritesheets()
	CRASH("create_spritesheets() not implemented for [type]")

/datum/asset/spritesheet_batched/proc/should_refresh(yield)
	var/meta_path = cache_meta_path()
	if(!fexists(meta_path))
		return BATCHED_CACHE_INVALID
	if(isnull(cache_data) || isnull(cache_shards_data))
		cache_data = file2text(meta_path)
		var/list/cache_json = safe_json_decode(cache_data)
		if(!islist(cache_json))
			log_asset("Invalid IconForge cache metadata for spritesheet_[name]")
			return BATCHED_CACHE_INVALID
		if(cache_json["rustg_version"] != rustg_get_version() || cache_json["dm_version"] != BATCHED_SPRITESHEET_VERSION)
			return BATCHED_CACHE_INVALID
		cache_sizes_data = cache_json["sizes"]
		cache_sprites_data = cache_json["sprites"]
		cache_sheet_files_data = cache_json["sheet_files"]
		cache_shards_data = cache_json["shards"]
		if(!length(cache_shards_data) || !length(cache_sizes_data) || !length(cache_sprites_data) || !length(cache_sheet_files_data))
			return BATCHED_CACHE_INVALID
		for(var/png_name in cache_sheet_files_data)
			if(!fexists("[SPRITESHEET_CACHE_DIR][png_name]"))
				return BATCHED_CACHE_INVALID

	if(!cache_shards_match(yield))
		return BATCHED_CACHE_INVALID
	sizes = cache_sizes_data
	sprites = cache_sprites_data
	sheet_files = cache_sheet_files_data
	return BATCHED_CACHE_VALID

/datum/asset/spritesheet_batched/proc/cache_shards_match(yield)
	var/list/shard_entries = list()
	var/shard_index = 1
	for(var/sprite_name in entries)
		shard_entries[sprite_name] = entries[sprite_name]
		if(length(shard_entries) < sprites_per_shard)
			continue
		if(shard_index > length(cache_shards_data) || !cache_shard_matches(cache_shards_data[shard_index], shard_entries, yield))
			return FALSE
		shard_index++
		shard_entries = list()
	if(length(shard_entries))
		if(shard_index > length(cache_shards_data) || !cache_shard_matches(cache_shards_data[shard_index], shard_entries, yield))
			return FALSE
		shard_index++
	return shard_index - 1 == length(cache_shards_data)

/datum/asset/spritesheet_batched/proc/cache_shard_matches(list/cache_shard, list/shard_entries, yield)
	if(!islist(cache_shard) || !length(cache_shard["input_hash"]) || !length(cache_shard["dmi_hashes"]))
		return FALSE
	var/input_hash = cache_shard["input_hash"]
	var/dmi_hashes_json = json_encode(cache_shard["dmi_hashes"])
	var/shard_json = json_encode(shard_entries)
	var/data_out
	if(yield || !isnull(cache_job_id))
		if(isnull(cache_job_id))
			cache_job_id = rustg_iconforge_cache_valid_async(input_hash, dmi_hashes_json, shard_json)
		UNTIL((data_out = rustg_iconforge_check(cache_job_id)) != RUSTG_JOB_NO_RESULTS_YET)
		cache_job_id = null
	else
		data_out = rustg_iconforge_cache_valid(input_hash, dmi_hashes_json, shard_json)
	if(data_out == RUSTG_JOB_ERROR || !findtext(data_out, "{", 1, 2))
		log_asset("IconForge cache validation failed for spritesheet_[name]: [data_out]")
		return FALSE
	var/list/result = safe_json_decode(data_out)
	return islist(result) && result["result"] == "1"

/datum/asset/spritesheet_batched/proc/read_from_cache()
	for(var/png_name in sheet_files)
		var/png_path = "[SPRITESHEET_CACHE_DIR][png_name]"
		if(!fexists(png_path))
			return FALSE
		var/png_hash = rustg_hash_file(RUSTG_HASH_MD5, png_path)
		SSassets.transport.register_asset(png_name, fcopy_rsc(file(png_path)), png_hash)
	register_css()
	return TRUE

/datum/asset/spritesheet_batched/proc/realize_spritesheets(yield)
	if(fully_generated)
		return
	if(generation_in_progress)
		// A second subsystem queue entry has nothing to do. A synchronous consumer,
		// however, must not observe a half-built sheet, so it waits for the owner.
		if(yield)
			return
		UNTIL(!generation_in_progress)
		if(fully_generated)
			return
		var/error_message = generation_error || "single-flight owner exited without a result"
		CRASH("IconForge generation failed for spritesheet_[name]: [error_message]")

	generation_in_progress = TRUE
	generation_error = null
	try
		realize_spritesheets_owned(yield)
	catch(var/exception/error)
		generation_error = error.name
		generation_in_progress = FALSE
		throw error
	generation_in_progress = FALSE

/datum/asset/spritesheet_batched/proc/realize_spritesheets_owned(yield)
	if(!length(entries))
		CRASH("Batched spritesheet [name] ([type]) is empty")
	if(sprites_per_shard <= 0)
		CRASH("Batched spritesheet [name] ([type]) has invalid sprites_per_shard [sprites_per_shard]")
	if(isnull(entries_json))
		entries_json = json_encode(entries)
	if(isnull(cache_result))
		cache_result = should_refresh(yield)
	if(cache_result == BATCHED_CACHE_VALID && read_from_cache())
		fully_generated = TRUE
		SSasset_loading.dequeue_asset(src)
		return

	fdel(cache_meta_path())
	// Versioned outputs may have a different shard count. Remove only this sheet's
	// PNGs before rebuilding so stale shards can never be published by webroot.
	for(var/existing_file in flist(SPRITESHEET_CACHE_DIR))
		if(findtextEx(existing_file, "[name]_part") == 1 && copytext(existing_file, -4) == ".png")
			fdel("[SPRITESHEET_CACHE_DIR][existing_file]")

	sizes = list()
	sprites = list()
	sheet_files = list()
	var/list/generated_cache_shards = list()
	var/list/shard_entries = list()
	var/shard_index = 1
	for(var/sprite_name in entries)
		shard_entries[sprite_name] = entries[sprite_name]
		if(length(shard_entries) < sprites_per_shard)
			continue
		generate_shard(shard_index++, shard_entries, generated_cache_shards, yield)
		shard_entries = list()
	if(length(shard_entries))
		generate_shard(shard_index, shard_entries, generated_cache_shards, yield)
	if(!length(sizes) || !length(sprites) || !length(sheet_files))
		CRASH("IconForge returned an empty result for spritesheet_[name]")

	for(var/png_name in sheet_files)
		var/png_path = "[SPRITESHEET_CACHE_DIR][png_name]"
		var/png_hash = rustg_hash_file(RUSTG_HASH_MD5, png_path)
		SSassets.transport.register_asset(png_name, fcopy_rsc(file(png_path)), png_hash)
	register_css()
	write_cache_meta(generated_cache_shards)
	fully_generated = TRUE
	SSasset_loading.dequeue_asset(src)

/datum/asset/spritesheet_batched/proc/generate_shard(shard_index, list/shard_entries, list/generated_cache_shards, yield)
	var/shard_name = "[name]_part[shard_index]"
	var/shard_json = json_encode(shard_entries)
	var/data_out
	if(yield || !isnull(job_id))
		if(isnull(job_id))
			job_id = rustg_iconforge_generate_async(SPRITESHEET_CACHE_DIR, shard_name, shard_json, TRUE, FALSE, TRUE)
		UNTIL((data_out = rustg_iconforge_check(job_id)) != RUSTG_JOB_NO_RESULTS_YET)
		job_id = null
	else
		data_out = rustg_iconforge_generate(SPRITESHEET_CACHE_DIR, shard_name, shard_json, TRUE, FALSE, TRUE)
	if(data_out == RUSTG_JOB_ERROR || !findtext(data_out, "{", 1, 2))
		CRASH("IconForge generation failed for spritesheet_[name] shard [shard_index]: [data_out]")
	var/list/generated = safe_json_decode(data_out)
	if(!islist(generated))
		CRASH("IconForge returned invalid JSON for spritesheet_[name] shard [shard_index]")
	var/list/shard_sizes = generated["sizes"]
	var/list/shard_sprites = generated["sprites"]
	if(generated["error"] && !(ignore_dir_errors && findtext(generated["error"], "is not in the set of valid dirs")))
		CRASH("Error during spritesheet generation for [name] shard [shard_index]: [generated["error"]]")
	if(!length(shard_sizes) || !length(shard_sprites))
		CRASH("IconForge returned an empty shard for spritesheet_[name] shard [shard_index]")
	for(var/size_id in shard_sizes)
		var/list/dimensions = splittext(size_id, "x")
		var/width = text2num(dimensions[1])
		var/sprites_of_size = 0
		for(var/sprite_name in shard_sprites)
			if(shard_sprites[sprite_name][BATCHED_SPR_SIZE] == size_id)
				sprites_of_size++
		if(width * sprites_of_size > BATCHED_MAX_SHEET_WIDTH)
			CRASH("IconForge spritesheet_[name] shard [shard_index] would be [width * sprites_of_size]px wide; lower sprites_per_shard from [sprites_per_shard]")
		var/png_name = "[shard_name]_[size_id].png"
		sizes[size_id] = TRUE
		sheet_files += png_name
		for(var/sprite_name in shard_sprites)
			var/list/sprite = shard_sprites[sprite_name]
			if(sprite[BATCHED_SPR_SIZE] == size_id)
				sprite[BATCHED_SPR_FILE] = png_name
	for(var/sprite_name in shard_sprites)
		sprites[sprite_name] = shard_sprites[sprite_name]
	generated_cache_shards.len++
	generated_cache_shards[generated_cache_shards.len] = list(
		"input_hash" = generated["sprites_hash"],
		"dmi_hashes" = generated["dmi_hashes"],
	)

/datum/asset/spritesheet_batched/proc/register_css()
	var/css_name = "spritesheet_[name].css"
	var/css_path = "[SPRITESHEET_CACHE_DIR][css_name]"
	fdel(css_path)
	var/css = generate_css()
	text2file(css, css_path)
	SSassets.transport.register_asset(css_name, fcopy_rsc(file(css_path)), rustg_hash_string(RUSTG_HASH_MD5, css))

/// Rebuilds transport-specific CSS without touching immutable IconForge PNGs.
/datum/asset/spritesheet_batched/refresh_css_for_transport(datum/asset_transport/new_transport)
	if(!fully_generated || SSassets.transport != new_transport)
		return
	new_transport.unregister_asset("spritesheet_[name].css")
	register_css()
	cached_url_mappings = null

/datum/asset/spritesheet_batched/proc/write_cache_meta(list/cache_shards)
	var/list/meta = list(
		"shards" = cache_shards,
		"sizes" = sizes,
		"sprites" = sprites,
		"sheet_files" = sheet_files,
		"rustg_version" = rustg_get_version(),
		"dm_version" = BATCHED_SPRITESHEET_VERSION,
	)
	fdel(cache_meta_path())
	text2file(json_encode(meta), cache_meta_path())

/datum/asset/spritesheet_batched/queued_generation()
	// Count the job before spawning it: SSasset_loading must not clean the
	// IconForge process cache in the gap between INVOKE_ASYNC and the proc body.
	SSasset_loading.assets_generating++
	INVOKE_ASYNC(src, PROC_REF(realize_queued_spritesheet))

/datum/asset/spritesheet_batched/proc/realize_queued_spritesheet()
	try
		realize_spritesheets(yield = TRUE)
	catch(var/exception/error)
		SSasset_loading.assets_generating--
		throw error
	SSasset_loading.assets_generating--

/datum/asset/spritesheet_batched/ensure_ready()
	if(!fully_generated)
		realize_spritesheets(yield = FALSE)
	return src

/datum/asset/spritesheet_batched/unregister()
	SSasset_loading.dequeue_asset(src)
	SSassets.transport.unregister_asset("spritesheet_[name].css")
	for(var/png_name in sheet_files)
		SSassets.transport.unregister_asset(png_name)

/datum/asset/spritesheet_batched/regenerate()
	unregister()
	entries = list()
	entries_json = null
	sizes = list()
	sprites = list()
	sheet_files = list()
	fully_generated = FALSE
	job_id = null
	cache_job_id = null
	cache_data = null
	cache_sizes_data = null
	cache_sprites_data = null
	cache_sheet_files_data = null
	cache_shards_data = null
	cache_result = null
	generation_in_progress = FALSE
	generation_error = null
	cached_url_mappings = null
	fdel(cache_meta_path())
	create_spritesheets()
	realize_spritesheets(yield = FALSE)
	return src

/datum/asset/spritesheet_batched/send(client/client)
	ensure_ready()
	var/list/all_assets = list("spritesheet_[name].css")
	for(var/png_name in sheet_files)
		all_assets += png_name
	return SSassets.transport.send_assets(client, all_assets)

/datum/asset/spritesheet_batched/get_url_mappings()
	ensure_ready()
	var/list/mappings = list("spritesheet_[name].css" = SSassets.transport.get_asset_url("spritesheet_[name].css"))
	for(var/png_name in sheet_files)
		mappings[png_name] = SSassets.transport.get_asset_url(png_name)
	return mappings

/datum/asset/spritesheet_batched/proc/generate_css()
	var/list/output = list()
	for(var/size_id in sizes)
		var/list/dimensions = splittext(size_id, "x")
		var/width = text2num(dimensions[1])
		var/height = text2num(dimensions[2])
		output += ".[name][size_id]{display:inline-block;width:[width]px;height:[height]px;background-repeat:no-repeat;}"
	for(var/sprite_id in sprites)
		var/list/sprite = sprites[sprite_id]
		var/size_id = sprite[BATCHED_SPR_SIZE]
		var/index = sprite[BATCHED_SPR_IDX]
		var/png_name = sprite[BATCHED_SPR_FILE]
		var/list/dimensions = splittext(size_id, "x")
		var/x = index * text2num(dimensions[1])
		output += ".[name][size_id].[sprite_id]{background-image:url('[SSassets.transport.get_asset_url(png_name)]');background-position:-[x]px 0;}"
	return output.Join("\n")

/datum/asset/spritesheet_batched/proc/css_tag()
	ensure_ready()
	return {"<link rel="stylesheet" href="[css_filename()]" />"}

/datum/asset/spritesheet_batched/proc/css_filename()
	ensure_ready()
	return SSassets.transport.get_asset_url("spritesheet_[name].css")

/datum/asset/spritesheet_batched/proc/icon_tag(sprite_name)
	ensure_ready()
	return icon_tag_if_ready(sprite_name)

/// Тег иконки без права на сон. ensure_ready() ждёт чужую генерацию листа
/// (UNTIL в realize_spritesheets), поэтому icon_tag() запрещён из цепочек
/// SHOULD_NOT_SLEEP - say(), Initialize(), обработчиков сигналов. Пока лист не
/// собран, честно возвращаем null: иконка в чате - косметика, одно сообщение
/// без неё в первые секунды раунда дешевле, чем спящий обработчик.
/datum/asset/spritesheet_batched/proc/icon_tag_if_ready(sprite_name)
	if(!fully_generated)
		return null
	var/list/sprite = sprites[sprite_name]
	if(!sprite)
		return null
	return "<span class='[name][sprite[BATCHED_SPR_SIZE]] [sprite_name]'></span>"

/datum/asset/spritesheet_batched/proc/icon_class_name(sprite_name)
	ensure_ready()
	var/list/sprite = sprites[sprite_name]
	if(!sprite)
		return null
	return "[name][sprite[BATCHED_SPR_SIZE]] [sprite_name]"

/datum/asset/spritesheet_batched/proc/icon_size_id(sprite_name)
	ensure_ready()
	var/list/sprite = sprites[sprite_name]
	if(!sprite)
		return null
	return "[name][sprite[BATCHED_SPR_SIZE]]"

#undef BATCHED_SPR_SIZE
#undef BATCHED_SPR_IDX
#undef BATCHED_SPR_FILE
#undef BATCHED_CACHE_INVALID
#undef BATCHED_CACHE_VALID
#undef BATCHED_SPRITESHEET_VERSION
#undef BATCHED_DEFAULT_SPRITES_PER_SHARD
#undef BATCHED_MAX_SHEET_WIDTH
