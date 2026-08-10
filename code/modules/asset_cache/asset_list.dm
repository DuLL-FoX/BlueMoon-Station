GLOBAL_LIST_EMPTY(asset_datums)

/// Returns a registered asset datum without forcing deferred generation.
/proc/load_asset_datum(type)
	return GLOB.asset_datums[type] || new type()

/// Returns a registered asset datum and guarantees that its files are ready.
/proc/get_asset_datum(type)
	var/datum/asset/loaded_asset = load_asset_datum(type)
	return loaded_asset.ensure_ready()

/datum/asset
	var/_abstract = /datum/asset
	var/cached_url_mappings
	var/cached_url_mappings_generation = -1
	/// Assets required before ordinary lazy generation may set this to TRUE.
	var/early = FALSE
	/// Internal SSasset_loading membership guard.
	var/generation_queued = FALSE

/datum/asset/New()
	GLOB.asset_datums[type] = src
	register()

/datum/asset/proc/ensure_ready()
	return src

/datum/asset/proc/queued_generation()
	CRASH("[type] was queued for asset generation without queued_generation()")

/datum/asset/proc/get_url_mappings()
	return list()

/datum/asset/proc/get_serialized_url_mappings()
	ensure_ready()
	if (isnull(cached_url_mappings) || cached_url_mappings_generation != GLOB.asset_url_generation)
		cached_url_mappings = TGUI_CREATE_MESSAGE("asset/mappings", get_url_mappings())
		cached_url_mappings_generation = GLOB.asset_url_generation

	return cached_url_mappings

/// Пересобирает транспорт-зависимые артефакты ассета под новый активный
/// транспорт (см. SSassets.invalidate_asset_urls). База - no-op: обычные ассеты
/// готовых URL внутри себя не держат, их адреса пересчитаются через
/// get_asset_url() после сброса cached_url_mappings.
/datum/asset/proc/refresh_css_for_transport(datum/asset_transport/new_transport)
	return

/datum/asset/proc/register()
	return

/datum/asset/proc/send(client)
	return

/// Immediately replaces this datum's registered files.
/datum/asset/proc/regenerate()
	unregister()
	cached_url_mappings = null
	cached_url_mappings_generation = -1
	register()
	return ensure_ready()

/datum/asset/proc/unregister()
	return

/datum/asset/simple
	_abstract = /datum/asset/simple
	var/assets = list()
	var/legacy = FALSE
	var/keep_local_name = FALSE

/datum/asset/simple/register()
	for(var/asset_name in assets)
		var/datum/asset_cache_item/ACI = SSassets.transport.register_asset(asset_name, assets[asset_name])
		if (!ACI)
			log_asset("ERROR: Invalid asset: [type]:[asset_name]:[ACI]")
			continue
		if (legacy)
			ACI.legacy = legacy
		if (keep_local_name)
			ACI.keep_local_name = keep_local_name
		assets[asset_name] = ACI

/datum/asset/simple/send(client)
	. = SSassets.transport.send_assets(client, assets)

/datum/asset/simple/get_url_mappings()
	. = list()
	for (var/asset_name in assets)
		.[asset_name] = SSassets.transport.get_asset_url(asset_name, assets[asset_name])

/datum/asset/simple/unregister()
	for(var/asset_name in assets)
		SSassets.transport.unregister_asset(asset_name)

/datum/asset/group
	_abstract = /datum/asset/group
	var/list/children

/datum/asset/group/register()
	for(var/type in children)
		load_asset_datum(type)

/datum/asset/group/send(client/C)
	for(var/type in children)
		var/datum/asset/A = get_asset_datum(type)
		. = A.send(C) || .

/datum/asset/group/get_url_mappings()
	. = list()
	for(var/type in children)
		var/datum/asset/A = get_asset_datum(type)
		. += A.get_url_mappings()

/datum/asset/group/unregister()
	for(var/type in children)
		var/datum/asset/child = load_asset_datum(type)
		child.unregister()

/**
 * Каталог кросс-раундового кэша спрайтшитов.
 *
 * Мир с UNIT_TESTS собирает не тот же набор спрайтов, что боевой (см.
 * assets/vending.dm - под тестами предметы с отсутствующим icon_state
 * пропускаются), поэтому листы у них разные побайтово. Пиши оба в один каталог -
 * и прогон dm-test поверх живого сервера перезапишет png/css прямо под ним:
 * раунд начнёт отдавать новое содержимое под старыми, уже посчитанными именами,
 * а css уедет ссылаться на png, которого под этим именем никто не отправлял.
 */
#ifdef UNIT_TESTS
#define SPRITESHEET_CACHE_DIR "data/spritesheets_unit_tests/"
#else
#define SPRITESHEET_CACHE_DIR "data/spritesheets/"
#endif

// Spritesheet asset
#define SPR_SIZE 1
#define SPR_IDX 2
#define SPRSZ_COUNT 1
#define SPRSZ_ICON 2
#define SPRSZ_STRIPPED 3

/datum/asset/spritesheet
	_abstract = /datum/asset/spritesheet
	var/name
	/// Insert() arguments waiting to be realized into BYOND /icon objects.
	var/list/to_generate = list()
	/// Next queued Insert() to realize. An index keeps FIFO order without Cut(1, 2).
	var/generation_index = 1
	/// Preserves the old immediate duplicate-name failure while Insert() is deferred.
	var/list/queued_sprite_names = list()
	var/list/sizes = list()    // "32x32" -> list(10, icon/normal, icon/stripped)
	var/list/sprites = list()  // "foo_bar" -> list("32x32", 5)
	var/fully_generated = FALSE
	var/load_immediately = FALSE

/// Bump when generate_css output format, ensure_stripped pipeline, or sprites dict layout
/// changes in a way that makes the previous round's cache files invalid. This makes rounds
/// after the bump regenerate even if input_signature happens to match.
#define SPRITESHEET_CACHE_VERSION 4

/datum/asset/spritesheet/register()
	if (!name)
		CRASH("spritesheet [type] cannot register without a name")
	create_spritesheets()
	if (should_load_immediately())
		realize_spritesheets(yield = FALSE)
	else
		SSasset_loading.queue_asset(src)

/datum/asset/spritesheet/proc/should_load_immediately()
#ifdef DO_NOT_DEFER_ASSETS
	return TRUE
#else
	return load_immediately || early
#endif

/// Override to populate this sheet with Insert()/InsertAll().
/datum/asset/spritesheet/proc/create_spritesheets()
	CRASH("create_spritesheets() not implemented for [type]")

/datum/asset/spritesheet/proc/realize_spritesheets(yield)
	if(fully_generated)
		return
	// BYOND 516 cannot reliably resume Insert() work against the same mutable
	// destination /icon after the proc yields: the next insertion fails with
	// "bad icon operation" and leaves the icon graph unsafe during shutdown.
	// Budget legacy work at the complete-datum boundary in SSasset_loading.
	// The genuinely heavy sheets use spritesheet_batched/async IconForge.
	while(generation_index <= length(to_generate))
		var/list/stored_args = to_generate[generation_index++]
		queuedInsert(arglist(stored_args))
	to_generate = list()
	generation_index = 1
	queued_sprite_names = list()
	register_realized_spritesheet()
	fully_generated = TRUE
	SSasset_loading.dequeue_asset(src)

/datum/asset/spritesheet/proc/register_realized_spritesheet()
	if (!name)
		CRASH("spritesheet [type] cannot register without a name")

	// Cross-round smart cache:
	// Insert() calls (ran by the subclass before this proc) have already populated
	// `sprites`/`sizes`. We then derive a signature from layout + per-size pixel content
	// + transport config (see the block below) and compare it to the metadata written
	// by the previous round. On a hit we skip ensure_stripped + generate_css + the
	// file-write churn and just register the PNG/CSS files left behind on disk.
	var/cache_meta_path = "[SPRITESHEET_CACHE_DIR]cache.[name].json"
	var/css_path = "[SPRITESHEET_CACHE_DIR]spritesheet_[name].css"

	// Signature has three parts:
	//   layout    — sprite name → (size_id, idx) mapping; catches added/removed/reordered sprites.
	//   content   — md5asfile() of each per-size source icon's pixel data; catches edits to the
	//               underlying DMI even when sprite names/positions are unchanged. Must be
	//               md5asfile() and NOT md5() — this repo doesn't define RUSTG_OVERRIDE_BUILTINS,
	//               so md5() on a file ref hashes the path string rather than the file contents.
	//   transport — invalidates the cached CSS when the asset transport class or its URL-shaping
	//               config changes (browse_rsc ↔ webroot, CDN URL change, dont_mutate_filenames
	//               toggle). generate_css() embeds get_asset_url() output directly, so a stale
	//               CSS from the previous transport would point at the wrong URLs.
	var/list/sorted_sprite_keys = sort_list(sprites)
	var/list/layout_payload = list()
	for(var/sprite_id in sorted_sprite_keys)
		layout_payload["[sprite_id]"] = sprites[sprite_id]

	var/list/sorted_size_keys = sort_list(sizes)
	var/list/content_payload = list()
	for(var/size_id in sorted_size_keys)
		var/icon/sheet = sizes[size_id][SPRSZ_ICON]
		content_payload["[size_id]"] = md5asfile(fcopy_rsc(sheet))

	var/transport_salt = "[SSassets.transport.type]:[CONFIG_GET(string/asset_cdn_url)]:[CONFIG_GET(string/asset_cdn_webroot)]:[SSassets.transport.dont_mutate_filenames]"

	var/input_signature = md5(json_encode(list(
		"v" = SPRITESHEET_CACHE_VERSION,
		"layout" = layout_payload,
		"content" = content_payload,
		"transport" = transport_salt,
	)))

	var/cache_valid = FALSE
	var/list/cached_png_hashes
	var/cached_css_hash
	if(fexists(cache_meta_path) && fexists(css_path))
		var/list/cached_meta = safe_json_decode(file2text(cache_meta_path))
		if(islist(cached_meta) && cached_meta["signature"] == input_signature)
			cached_png_hashes = cached_meta["png_hashes"]
			cached_css_hash = cached_meta["css_hash"]
			if(islist(cached_png_hashes) && cached_css_hash)
				cache_valid = TRUE
				for(var/size_id in sizes)
					if(!fexists("[SPRITESHEET_CACHE_DIR][name]_[size_id].png") || !cached_png_hashes["[size_id]"])
						cache_valid = FALSE
						break
			else
				cache_valid = FALSE

	// fcopy_rsc() снимает с файла неизменяемый слепок. Без него asset_cache_item
	// держит ленивую ссылку на путь: хэш (а с ним и имя, под которым ассет уедет
	// клиенту) фиксируется здесь, а байты читаются только в момент browse_rsc().
	// Любая перезапись каталога между стартом раунда и открытием окна тогда молча
	// разводит имя и содержимое - клиент получает css, который ссылается на png,
	// не отправленный ни под каким именем.
	//
	// Хэши из метаданных - обещание о содержимом файлов. Не сошлось - кэш испорчен
	// (чужой мир в том же каталоге, правка руками, оборванная запись), и доверять
	// ему нельзя целиком: молча отдать битый лист хуже, чем пересобрать.
	var/css_snapshot
	if(cache_valid)
		css_snapshot = fcopy_rsc(file(css_path))
		if(md5asfile(css_snapshot) != cached_css_hash)
			cache_valid = FALSE

	var/list/png_snapshots = list()
	if(cache_valid)
		for(var/size_id in sizes)
			var/png_snapshot = fcopy_rsc(file("[SPRITESHEET_CACHE_DIR][name]_[size_id].png"))
			if(md5asfile(png_snapshot) != cached_png_hashes["[size_id]"])
				cache_valid = FALSE
				break
			png_snapshots["[size_id]"] = png_snapshot

	if(cache_valid)
		for(var/size_id in sizes)
			SSassets.transport.register_asset("[name]_[size_id].png", png_snapshots["[size_id]"], cached_png_hashes["[size_id]"], null)
		SSassets.transport.register_asset("spritesheet_[name].css", css_snapshot, cached_css_hash, null)
		return

	// Cache miss: full regeneration. ensure_stripped(keep_file=TRUE) leaves the PNG on
	// disk so the next round can cache-hit; we register from the file directly instead
	// of from the loaded /icon datum so asset_cache_item hashes match across rounds.
	var/list/current_png_files = list()
	for(var/size_id in sizes)
		current_png_files["[name]_[size_id].png"] = TRUE

	for(var/existing_png in flist(SPRITESHEET_CACHE_DIR))
		if(findtextEx(existing_png, "[name]_") != 1 || copytext(existing_png, -4) != ".png")
			continue
		if(existing_png in current_png_files)
			continue
		fdel("[SPRITESHEET_CACHE_DIR][existing_png]")

	ensure_stripped(keep_file = TRUE)
	var/list/png_hashes = list()
	for(var/size_id in sizes)
		var/png_path = "[SPRITESHEET_CACHE_DIR][name]_[size_id].png"
		var/datum/asset_cache_item/ACI = SSassets.transport.register_asset("[name]_[size_id].png", fcopy_rsc(file(png_path)))
		png_hashes["[size_id]"] = ACI.hash

	fdel(css_path)
	text2file(generate_css(), css_path)
	var/datum/asset_cache_item/css_item = SSassets.transport.register_asset("spritesheet_[name].css", fcopy_rsc(file(css_path)))

	fdel(cache_meta_path)
	text2file(json_encode(list(
		"signature" = input_signature,
		"png_hashes" = png_hashes,
		"css_hash" = css_item.hash,
	)), cache_meta_path)

#undef SPRITESHEET_CACHE_VERSION

/// Пересобирает css листа под новый активный транспорт: generate_css() вшивает
/// get_asset_url() прямо в текст (см. transport-часть подписи кэша выше).
/// Нереализованный лист не трогаем: он зарегистрирует css уже при новом
/// транспорте, когда доедет до register_realized_spritesheet().
/datum/asset/spritesheet/refresh_css_for_transport(datum/asset_transport/new_transport)
	if (!fully_generated || !name || SSassets.transport != new_transport)
		return
	// Лист, пришедший из кросс-раундового кэша, ни разу не проходил ensure_stripped -
	// generate_css() на нём падал бы на пустом SPRSZ_STRIPPED и обрывал инвалидацию
	// на середине списка ассетов.
	ensure_stripped(keep_file = TRUE)
	var/css_path = "[SPRITESHEET_CACHE_DIR]spritesheet_[name].css"
	fdel(css_path)
	text2file(generate_css(), css_path)
	// Старую запись снимаем сами: register_asset() на то же имя с другим хэшом
	// считает это ошибкой и пишет stack_trace на каждый лист.
	new_transport.unregister_asset("spritesheet_[name].css")
	// fcopy_rsc() снимает неизменяемый слепок. Без него ассет держит ленивую
	// ссылку на путь: имя фиксируется сейчас, а байты читаются в момент
	// browse_rsc(), и следующая перезапись каталога (соседний DreamDaemon на том
	// же деплое, прогон dm-test) разведёт имя и содержимое.
	new_transport.register_asset("spritesheet_[name].css", fcopy_rsc(file(css_path)))

/datum/asset/spritesheet/queued_generation()
	realize_spritesheets(yield = TRUE)

/datum/asset/spritesheet/ensure_ready()
	if(!fully_generated)
		realize_spritesheets(yield = FALSE)
	return src

/datum/asset/spritesheet/unregister()
	SSasset_loading.dequeue_asset(src)
	SSassets.transport.unregister_asset("spritesheet_[name].css")
	for(var/size_id in sizes)
		SSassets.transport.unregister_asset("[name]_[size_id].png")

/datum/asset/spritesheet/regenerate()
	unregister()
	var/cache_meta_path = "[SPRITESHEET_CACHE_DIR]cache.[name].json"
	fdel(cache_meta_path)
	for(var/size_id in sizes)
		fdel("[SPRITESHEET_CACHE_DIR][name]_[size_id].png")
	fdel("[SPRITESHEET_CACHE_DIR]spritesheet_[name].css")
	to_generate = list()
	generation_index = 1
	queued_sprite_names = list()
	sizes = list()
	sprites = list()
	fully_generated = FALSE
	cached_url_mappings = null
	cached_url_mappings_generation = -1
	create_spritesheets()
	realize_spritesheets(yield = FALSE)
	return src

/datum/asset/spritesheet/send(client/C)
	if (!name)
		return
	ensure_ready()
	var/all = list("spritesheet_[name].css")
	for(var/size_id in sizes)
		all += "[name]_[size_id].png"
	. = SSassets.transport.send_assets(C, all)

/datum/asset/spritesheet/get_url_mappings()
	if (!name)
		return
	ensure_ready()
	. = list("spritesheet_[name].css" = SSassets.transport.get_asset_url("spritesheet_[name].css"))
	for(var/size_id in sizes)
		.["[name]_[size_id].png"] = SSassets.transport.get_asset_url("[name]_[size_id].png")

/datum/asset/json
	_abstract = /datum/asset/json
	/// Filename (without .json extension) used to register and serve the asset
	var/name
	var/fully_generated = FALSE
	var/load_immediately = FALSE

/datum/asset/json/register()
	if(!name)
		CRASH("datum/asset/json [type] cannot register without a name")
	if(load_immediately || early)
		realize_json()
	else
		SSasset_loading.queue_asset(src)

/datum/asset/json/proc/realize_json()
	if(fully_generated)
		return
	var/list/data = generate()
	var/fname = "data/asset_cache/[name].json"
	fdel(fname)
	text2file(json_encode(data), fname)
	SSassets.transport.register_asset("[name].json", fcopy_rsc(fname))
	fdel(fname)
	fully_generated = TRUE
	SSasset_loading.dequeue_asset(src)

/datum/asset/json/queued_generation()
	realize_json()

/datum/asset/json/ensure_ready()
	if(!fully_generated)
		realize_json()
	return src

/datum/asset/json/unregister()
	SSasset_loading.dequeue_asset(src)
	SSassets.transport.unregister_asset("[name].json")

/datum/asset/json/regenerate()
	unregister()
	fully_generated = FALSE
	cached_url_mappings = null
	cached_url_mappings_generation = -1
	realize_json()
	return src

/datum/asset/json/proc/generate()
	CRASH("datum/asset/json [type] did not implement generate()")

/datum/asset/json/send(client/C)
	ensure_ready()
	return SSassets.transport.send_assets(C, list("[name].json"))

/datum/asset/json/get_url_mappings()
	ensure_ready()
	return list("[name].json" = SSassets.transport.get_asset_url("[name].json"))

/// keep_file: if TRUE, the stripped PNG on disk is left in place (used by the smart
/// cross-round cache so the next start can re-register it without rebuilding).
/datum/asset/spritesheet/proc/ensure_stripped(sizes_to_strip = sizes, keep_file = FALSE)
	for(var/size_id in sizes_to_strip)
		var/size = sizes[size_id]
		if (size[SPRSZ_STRIPPED])
			continue

		// save flattened version
		var/fname = "[SPRITESHEET_CACHE_DIR][name]_[size_id].png"
		fcopy(size[SPRSZ_ICON], fname)
		var/error = rustg_dmi_strip_metadata(fname)
		if(length(error))
			stack_trace("Failed to strip [name]_[size_id].png: [error]")
		size[SPRSZ_STRIPPED] = icon(fname)
		if(!keep_file)
			fdel(fname)

/datum/asset/spritesheet/proc/generate_css()
	var/list/out = list()

	for (var/size_id in sizes)
		var/size = sizes[size_id]
		var/icon/tiny = size[SPRSZ_ICON]
		out += ".[name][size_id]{display:inline-block;width:[tiny.Width()]px;height:[tiny.Height()]px;background:url('[SSassets.transport.get_asset_url("[name]_[size_id].png")]') no-repeat;}"

	for (var/sprite_id in sprites)
		var/sprite = sprites[sprite_id]
		var/size_id = sprite[SPR_SIZE]
		var/idx = sprite[SPR_IDX]
		var/size = sizes[size_id]

		var/icon/tiny = size[SPRSZ_ICON]
		var/icon/big = size[SPRSZ_STRIPPED]
		var/per_line = big.Width() / tiny.Width()
		var/x = (idx % per_line) * tiny.Width()
		var/y = round(idx / per_line) * tiny.Height()

		out += ".[name][size_id].[sprite_id]{background-position:-[x]px -[y]px;}"

	return out.Join("\n")

/// Возвращает TRUE, если спрайт реально попал в шит. Вызывающий может передать
/// сюда сам файл иконки со стейтом и не резать icon() у себя заранее.
/datum/asset/spritesheet/proc/Insert(sprite_name, icon/I, icon_state="", dir=SOUTH, frame=1, moving=FALSE)
	if(should_load_immediately())
		return queuedInsert(sprite_name, I, icon_state, dir, frame, moving)
	if(queued_sprite_names[sprite_name] || sprites[sprite_name])
		CRASH("duplicate sprite \"[sprite_name]\" in sheet [name] ([type])")
	// Runtime /icon values are mutable datums. Some legacy sheets build them with a
	// temporary painter and then mutate or release the source before this queue is
	// realized. Capture the selected frame and sheet-specific modification now,
	// then retain only BYOND's immutable resource copy across ticks.
	if(isicon(I) && "[I]" == "/icon")
		var/icon/snapshot = icon(I, icon_state=icon_state, dir=dir, frame=frame, moving=moving)
		if(!snapshot || !length(icon_states(snapshot)))
			return FALSE
		snapshot = ModifyInserted(snapshot)
		var/snapshot_resource = fcopy_rsc(snapshot)
		queued_sprite_names[sprite_name] = TRUE
		to_generate += list(list(sprite_name, snapshot_resource, "", SOUTH, 1, FALSE, TRUE))
		return TRUE
	queued_sprite_names[sprite_name] = TRUE
	to_generate += list(args.Copy())
	return TRUE

/datum/asset/spritesheet/proc/queuedInsert(sprite_name, icon/I, icon_state="", dir=SOUTH, frame=1, moving=FALSE, already_modified=FALSE)
	I = icon(I, icon_state=icon_state, dir=dir, frame=frame, moving=moving)
	if (!I || !length(icon_states(I)))  // that direction or state doesn't exist
		return FALSE
	//any sprite modifications we want to do (aka, coloring a greyscaled asset)
	if(!already_modified)
		I = ModifyInserted(I)
	var/size_id = "[I.Width()]x[I.Height()]"
	var/size = sizes[size_id]

	if (sprites[sprite_name])
		CRASH("duplicate sprite \"[sprite_name]\" in sheet [name] ([type])")

	if (size)
		var/position = size[SPRSZ_COUNT]++
		var/icon/sheet = size[SPRSZ_ICON]
		size[SPRSZ_STRIPPED] = null
		sheet.Insert(I, icon_state=sprite_name)
		sprites[sprite_name] = list(size_id, position)
	else
		sizes[size_id] = size = list(1, I, null)
		sprites[sprite_name] = list(size_id, 0)
	return TRUE

/**
 * A simple proc handing the Icon for you to modify before it gets turned into an asset.
 *
 * Arguments:
 * * I: icon being turned into an asset
 */
/datum/asset/spritesheet/proc/ModifyInserted(icon/pre_asset)
	return pre_asset

/datum/asset/spritesheet/proc/InsertAll(prefix, icon/I, list/directions)
	if (length(prefix))
		prefix = "[prefix]-"

	if (!directions)
		directions = list(SOUTH)

	for (var/icon_state_name in icon_states(I))
		for (var/direction in directions)
			var/prefix2 = (directions.len > 1) ? "[dir2text(direction)]-" : ""
			Insert("[prefix][prefix2][icon_state_name]", I, icon_state=icon_state_name, dir=direction)

/datum/asset/spritesheet/proc/css_tag()
	ensure_ready()
	return {"<link rel="stylesheet" href="[css_filename()]" />"}

/datum/asset/spritesheet/proc/css_filename()
	ensure_ready()
	return SSassets.transport.get_asset_url("spritesheet_[name].css")

/datum/asset/spritesheet/proc/icon_tag(sprite_name)
	ensure_ready()
	var/sprite = sprites[sprite_name]
	if (!sprite)
		return null
	var/size_id = sprite[SPR_SIZE]
	return {"<span class="[name][size_id] [sprite_name]"></span>"}

/datum/asset/spritesheet/proc/icon_class_name(sprite_name)
	ensure_ready()
	var/sprite = sprites[sprite_name]
	if (!sprite)
		return null
	var/size_id = sprite[SPR_SIZE]
	return {"[name][size_id] [sprite_name]"}

/**
 * Returns the size class (ex design32x32) for a given sprite's icon
 *
 * Arguments:
 * * sprite_name - The sprite to get the size of
 */
/datum/asset/spritesheet/proc/icon_size_id(sprite_name)
	ensure_ready()
	var/sprite = sprites[sprite_name]
	if (!sprite)
		return null
	var/size_id = sprite[SPR_SIZE]
	return "[name][size_id]"

#undef SPR_SIZE
#undef SPR_IDX
#undef SPRSZ_COUNT
#undef SPRSZ_ICON
#undef SPRSZ_STRIPPED


/datum/asset/changelog_item
	_abstract = /datum/asset/changelog_item
	var/item_filename

/datum/asset/changelog_item/New(date)
	item_filename = sanitize_filename("[date].yml")
	SSassets.transport.register_asset(item_filename, file("html/changelogs/archive/" + item_filename))

/datum/asset/changelog_item/send(client)
	if (!item_filename)
		return
	. = SSassets.transport.send_assets(client, item_filename)

/datum/asset/changelog_item/get_url_mappings()
	if (!item_filename)
		return
	. = list("[item_filename]" = SSassets.transport.get_asset_url(item_filename))

/datum/asset/spritesheet/simple
	_abstract = /datum/asset/spritesheet/simple
	var/list/assets

/datum/asset/spritesheet/simple/create_spritesheets()
	for (var/key in assets)
		Insert(key, assets[key])

//Generates assets based on iconstates of a single icon
/datum/asset/simple/icon_states
	_abstract = /datum/asset/simple/icon_states
	var/icon
	var/list/directions = list(SOUTH)
	var/frame = 1
	var/movement_states = FALSE

	var/prefix = "default" //asset_name = "[prefix].[icon_state_name].png"
	var/generic_icon_names = FALSE //generate icon filenames using generate_asset_name() instead the above format

/datum/asset/simple/icon_states/register(_icon = icon)
	for(var/icon_state_name in icon_states(_icon))
		for(var/direction in directions)
			var/asset = icon(_icon, icon_state_name, direction, frame, movement_states)
			if (!asset)
				continue
			asset = fcopy_rsc(asset) //dedupe
			var/prefix2 = (directions.len > 1) ? "[dir2text(direction)]." : ""
			var/asset_name = sanitize_filename("[prefix].[prefix2][icon_state_name].png")
			if (generic_icon_names)
				asset_name = "[generate_asset_name(asset)].png"

			SSassets.transport.register_asset(asset_name, asset)

/datum/asset/simple/icon_states/multiple_icons
	_abstract = /datum/asset/simple/icon_states/multiple_icons
	var/list/icons

/datum/asset/simple/icon_states/multiple_icons/register()
	for(var/i in icons)
		..(i)

/// Namespace'ed assets (for static css and html files)
/// When sent over a cdn transport, all assets in the same asset datum will exist in the same folder, as their plain names.
/// Used to ensure css files can reference files by url() without having to generate the css at runtime, both the css file and the files it depends on must exist in the same namespace asset datum. (Also works for html)
/// For example `blah.css` with asset `blah.png` will get loaded as `namespaces/a3d..14f/f12..d3c.css` and `namespaces/a3d..14f/blah.png`. allowing the css file to load `blah.png` by a relative url rather then compute the generated url with get_url_mappings().
/// The namespace folder's name will change if any of the assets change. (excluding parent assets)
/datum/asset/simple/namespaced
	_abstract = /datum/asset/simple/namespaced
	/// parents - list of the parent asset or assets (in name = file assoicated format) for this namespace.
	/// parent assets must be referenced by their generated url, but if an update changes a parent asset, it won't change the namespace's identity.
	var/list/parents = list()

/datum/asset/simple/namespaced/register()
	if (legacy)
		assets |= parents
	var/list/hashlist = list()
	var/list/sorted_assets = sort_list(assets)

	for (var/asset_name in sorted_assets)
		var/datum/asset_cache_item/ACI = new(asset_name, sorted_assets[asset_name])
		if (!ACI?.hash)
			log_asset("ERROR: Invalid asset: [type]:[asset_name]:[ACI]")
			continue
		hashlist += ACI.hash
		sorted_assets[asset_name] = ACI
	var/namespace = md5(hashlist.Join())

	for (var/asset_name in parents)
		var/datum/asset_cache_item/ACI = new(asset_name, parents[asset_name])
		if (!ACI?.hash)
			log_asset("ERROR: Invalid asset: [type]:[asset_name]:[ACI]")
			continue
		ACI.namespace_parent = TRUE
		sorted_assets[asset_name] = ACI

	for (var/asset_name in sorted_assets)
		var/datum/asset_cache_item/ACI = sorted_assets[asset_name]
		if (!ACI?.hash)
			log_asset("ERROR: Invalid asset: [type]:[asset_name]:[ACI]")
			continue
		ACI.namespace = namespace

	assets = sorted_assets
	..()

/// Get a html string that will load a html asset.
/// Needed because byond doesn't allow you to browse() to a url.
/datum/asset/simple/namespaced/proc/get_htmlloader(filename)
	return url2htmlloader(SSassets.transport.get_asset_url(filename, assets[filename]))

