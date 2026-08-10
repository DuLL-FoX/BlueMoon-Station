/// Сколько раз за раунд транспорт ассетов срывался с CDN на раздачу через
/// DreamDaemon. Ноль здесь - единственный надёжный ответ на вопрос "мы всё ещё
/// на CDN?": конфиг после срыва продолжает показывать webroot.
GLOBAL_VAR_INIT(asset_transport_fallbacks, 0)
/// Причина последнего срыва: адрес или путь, который перестал отвечать.
GLOBAL_VAR(asset_transport_fallback_reason)
/// world.time последнего срыва, 0 - срывов не было.
GLOBAL_VAR_INIT(asset_transport_fallback_time, 0)
/// Растёт каждый раз, когда адреса ассетов перестают быть прежними. Всё, что
/// кеширует готовый URL на весь раунд, обязано сверяться с этим числом: иначе
/// после срыва CDN окна продолжат показывать адреса мёртвого хоста.
GLOBAL_VAR_INIT(asset_url_generation, 0)

/// CDN Webroot asset transport.
/datum/asset_transport/webroot
	name = "CDN Webroot asset transport"
	/// Assets absent from the build-owned release are routed through browse_rsc.
	var/local_asset_count = 0
	/// Неймспейс -> TRUE, если хотя бы одному его члену не нашлось build-копии.
	/// null означает "ещё не строили". Строится одним проходом по кешу на первый
	/// же вопрос: без индекса каждый namespaced-ассет стоил бы полного обхода
	/// SSassets.cache, а обход зовётся и на выдаче URL, и на отправке ассетов
	/// клиенту, то есть цена росла как размер кеша на каждое открытое окно.
	var/list/incomplete_namespaces

/datum/asset_transport/webroot/Load()
	if (validate_config(log = FALSE))
		load_existing_assets()

/// Emergency whole-transport fallback used when the external endpoint itself
/// fails. A file missing from the release uses the per-asset local route
/// instead. Публикацией транспорт больше не занимается (её увёз деплой),
/// поэтому единственный, кто видит смерть внешней раздачи с сервера, - это
/// SScdn_probe; он сюда и ходит. Инвалидацию выданных URL и перезаливку
/// открытых окон делает SSassets.invalidate_asset_urls().
/datum/asset_transport/webroot/proc/fallback_to_simple_transport(reason)
	log_asset("ERROR: [type]: CDN webroot is unreachable: [reason].")
	if (SSassets.transport != src)
		// Транспорт уже сорвался и заменён - считать это вторым срывом нельзя,
		// иначе счётчик распухнет от повторных сигналов одного сбоя.
		return
	GLOB.asset_transport_fallbacks++
	GLOB.asset_transport_fallback_reason = reason
	GLOB.asset_transport_fallback_time = world.time
	log_asset("ERROR: [type]: Falling back to simple transport (fallback #[GLOB.asset_transport_fallbacks]): browser assets are now served by DreamDaemon.")
	SSblackbox.record_feedback("tally", "resource_delivery_fallback", 1, "asset_transport")
	var/datum/asset_transport/simple_transport = new
	SSassets.transport = simple_transport
	simple_transport.Initialize(SSassets.cache)
	message_admins("Транспорт ассетов переключён на BYOND: CDN недоступен ([reason]). Интерфейсы будут грузиться медленнее.")
	SSassets.invalidate_asset_urls()

/// Processes thru any assets that were registered before we were loaded as a transport.
/datum/asset_transport/webroot/proc/load_existing_assets()
	for (var/asset_name in SSassets.cache)
		if (SSassets.transport != src)
			return
		var/datum/asset_cache_item/ACI = SSassets.cache[asset_name]
		classify_asset_route(ACI)

/// Register a browser asset and bind it to its external or local route.
/// asset_name - the identifier of the asset
/// asset - the actual asset file or an asset_cache_item datum.
/datum/asset_transport/webroot/register_asset(asset_name, asset, file_hash, dmi_file_path)
	. = ..()
	var/datum/asset_cache_item/ACI = .

	if (istype(ACI) && ACI.hash)
		classify_asset_route(ACI)

/// Selects the route without mutating the public store. PostCompile owns that
/// store; assets generated only inside DreamDaemon use the local transport.
/datum/asset_transport/webroot/proc/classify_asset_route(datum/asset_cache_item/ACI)
	var/webroot = CONFIG_GET(string/asset_cdn_webroot)
	var/relative_path = get_asset_suffex(ACI)
	var/newpath = "[webroot][relative_path]"
	if (fexists(newpath))
		if (webroot_asset_is_complete(ACI, newpath))
			ACI.external_available = TRUE
			return TRUE
	if (fexists("[newpath].gz")) //its a common pattern in webhosting to save gzip'ed versions of text files and let the webserver serve them up as gzip compressed normal files, sometimes without keeping the original version.
		ACI.external_available = TRUE
		return TRUE
	ACI.external_available = FALSE
	local_asset_count++
	note_incomplete_namespace(ACI)
	return FALSE

/// Помечает неймспейс ассета неполным. Пометка только в одну сторону, и это не
/// экономия, а требование безопасности: пропущенный локальный член выдал бы
/// клиенту адрес несуществующего файла, а лишняя пометка стоит одной картинки
/// через DreamDaemon. Обратный переход невозможен по устройству: публичный
/// каталог принадлежит PostCompile, DreamDaemon в него не пишет, так что
/// файл не может появиться посреди раунда.
/datum/asset_transport/webroot/proc/note_incomplete_namespace(datum/asset_cache_item/ACI)
	if (!ACI.namespace || isnull(incomplete_namespaces))
		// Индекса ещё нет - пересборка возьмёт правду из самого кеша.
		return
	incomplete_namespaces[ACI.namespace] = TRUE

/// TRUE when an already published file matches the size of the asset it stands
/// for. The name is a content hash, so equal size plus equal name is as strong
/// a check as rehashing every file on every boot would be.
/datum/asset_transport/webroot/proc/webroot_asset_is_complete(datum/asset_cache_item/ACI, published_path)
	if (!isfile(ACI.resource))
		return TRUE
	var/expected_size = length(ACI.resource)
	if (!expected_size)
		return TRUE
	return length(file(published_path)) == expected_size

/// Returns a url for a given asset.
/// asset_name - Name of the asset.
/// asset_cache_item - asset cache item datum for the asset, optional, overrides asset_name
/datum/asset_transport/webroot/get_asset_url(asset_name, datum/asset_cache_item/asset_cache_item)
	if (!istype(asset_cache_item))
		asset_cache_item = SSassets.cache[asset_name]
	if (!asset_is_external(asset_cache_item))
		return ..()
	var/url = CONFIG_GET(string/asset_cdn_url) //config loading will handle making sure this ends in a /
	return "[url][get_asset_suffex(asset_cache_item)]"

/// Namespace children use relative URLs, so one missing member makes the whole
/// namespace local. Non-namespaced assets can fail over independently.
/datum/asset_transport/webroot/proc/asset_is_external(datum/asset_cache_item/asset_cache_item)
	if (!istype(asset_cache_item) || !asset_cache_item.external_available)
		return FALSE
	if (!asset_cache_item.namespace)
		return TRUE
	if (isnull(incomplete_namespaces))
		rebuild_namespace_index()
	return !incomplete_namespaces[asset_cache_item.namespace]

/// Один проход по кешу отвечает сразу за все неймспейсы, поэтому пересборка
/// стоит ровно столько же, сколько стоил один прежний скан, а все следующие
/// вопросы - ничего.
/datum/asset_transport/webroot/proc/rebuild_namespace_index()
	incomplete_namespaces = list()
	for (var/cached_name in SSassets.cache)
		var/datum/asset_cache_item/cached_item = SSassets.cache[cached_name]
		if (cached_item.namespace && !cached_item.external_available)
			incomplete_namespaces[cached_item.namespace] = TRUE

/datum/asset_transport/webroot/proc/get_asset_suffex(datum/asset_cache_item/asset_cache_item)
	var/base = "[copytext(asset_cache_item.hash, 1, 3)]/"
	var/filename = "asset.[asset_cache_item.hash][asset_cache_item.ext]"
	if (length(asset_cache_item.namespace))
		base = "namespaces/[copytext(asset_cache_item.namespace, 1, 3)]/[asset_cache_item.namespace]/"
		if (!asset_cache_item.namespace_parent)
			filename = "[asset_cache_item.name]"
	return base + filename


/// Send only the local side of the composite route through DreamDaemon.
/datum/asset_transport/webroot/send_assets(client/client, list/asset_list)
	. = FALSE
	var/list/local_assets = list()
	if (!islist(asset_list))
		asset_list = list(asset_list)
	for (var/asset_name in asset_list)
		var/datum/asset_cache_item/ACI = asset_list[asset_name] 
		if (!istype(ACI))
			ACI = SSassets.cache[asset_name]
		if (!ACI)
			local_assets += asset_name //pass it on to base send_assets so it can output an error
			continue
		if (ACI.legacy || !asset_is_external(ACI))
			local_assets[asset_name] = ACI
	if (length(local_assets))
		. = ..(client, local_assets)
	

/// webroot slow asset sending - does nothing.
/datum/asset_transport/webroot/send_assets_slow(client/client, list/files, filerate)
	return FALSE

/datum/asset_transport/webroot/validate_config(log = TRUE)
	if (!CONFIG_GET(string/asset_cdn_url))
		if (log)
			log_asset("ERROR: [type]: Invalid Config: ASSET_CDN_URL")
		return FALSE
	var/webroot = CONFIG_GET(string/asset_cdn_webroot)
	if (!webroot)
		if (log)
			log_asset("ERROR: [type]: Invalid Config: ASSET_CDN_WEBROOT")
		return FALSE
	return TRUE
