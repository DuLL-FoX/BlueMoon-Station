SUBSYSTEM_DEF(assets)
	name = "Assets"
	init_order = INIT_ORDER_ASSETS
	flags = SS_NO_FIRE
	var/list/cache = list()
	var/list/preload = list()
	var/datum/asset_transport/transport = new()

/datum/controller/subsystem/assets/OnConfigLoad()
	var/newtransporttype = /datum/asset_transport
	switch (CONFIG_GET(string/asset_transport))
		if ("webroot")
			newtransporttype = /datum/asset_transport/webroot

	if (newtransporttype != transport.type)
		var/datum/asset_transport/newtransport = new newtransporttype ()
		if (newtransport.validate_config())
			transport = newtransport
		transport.Load()

	log_active_transport()

/**
 * Полная инвалидация всех URL, выданных прежним транспортом ассетов.
 *
 * Обязательна после каждой смены transport (и после переключения
 * dont_mutate_filenames) на живом мире: готовые адреса лежат в кешах
 * ассет-датумов, вшиты в css спрайтшитов и в статику открытых окон, и без
 * инвалидации клиенты до конца раунда ходят по адресам мёртвого хоста.
 *
 * Зовётся вербом Toggle CDN и аварийным fallback_to_simple_transport(), а не
 * из OnConfigLoad(): верб донастраивает новый транспорт (dont_mutate_filenames)
 * уже после смены, а пересборка css обязана видеть окончательную форму URL.
 */
/datum/controller/subsystem/assets/proc/invalidate_asset_urls()
	GLOB.asset_url_generation++
	// Лобби кеширует адрес своего JS на весь раунд, а он тоже выдан транспортом.
	if (SStitle_bm)
		SStitle_bm.cached_js_url = ""
	for (var/asset_type in GLOB.asset_datums)
		var/datum/asset/cached_asset = GLOB.asset_datums[asset_type]
		cached_asset.cached_url_mappings = null
		cached_asset.refresh_css_for_transport(transport)
	// Адреса ассетов вшиты в уже отправленную статику открытых окон, поэтому
	// обновления одних только кешей мало: интерфейсы надо заставить перезабрать
	// данные. Событие редкое, полный апдейт по всем окнам дешевле, чем раунд с
	// мёртвыми ссылками.
	INVOKE_ASYNC(src, PROC_REF(refresh_open_interfaces))

/// Пересылает открытым tgui-окнам их ассеты и статику после смены транспорта.
/// Отдельным проком и асинхронно: сбор нагрузки спит внутри ui_data()/ui_static_data(),
/// а инвалидация может прийти посреди сна вызывающего кода.
/datum/controller/subsystem/assets/proc/refresh_open_interfaces()
	if (!SStgui)
		return
	for (var/datum/tgui/open_ui in SStgui.open_uis.Copy())
		var/datum/tgui_window/window = open_ui.window
		if (!window?.client)
			continue
		var/list/window_assets = window.sent_assets
		for (var/datum/asset/sent_asset in window_assets.Copy())
			window.send_asset(sent_asset)
		open_ui.send_full_update(force = TRUE, ignore_cooldown = TRUE)
		// Полный апдейт зовёт ui_data()/ui_static_data() каждого окна, а их на полной
		// станции десятки. Без уступки тика вся пачка ложится в один тик и превращает
		// смену транспорта в фриз поверх уже случившейся аварии.
		CHECK_TICK

/// Записывает фактический транспорт браузерных ассетов и адрес, с которого их
/// будут забирать клиенты. Транспорт молча откатывается на раздачу через
/// DreamDaemon, если конфиг CDN не проходит проверку, и без этой строки
/// сорвавшийся CDN выглядит в логах ровно как исправный.
/datum/controller/subsystem/assets/proc/log_active_transport()
	var/configured = CONFIG_GET(string/asset_transport) || "simple"
	var/datum/asset_transport/webroot/webroot_transport = transport
	if (istype(webroot_transport))
		log_asset("Asset transport: [transport.name] (config: [configured]), url: [CONFIG_GET(string/asset_cdn_url)], read-only webroot: [CONFIG_GET(string/asset_cdn_webroot)], local routes: [webroot_transport.local_asset_count]")
		return
	if (configured == "webroot")
		log_asset("ERROR: Asset transport: config asks for webroot, but [transport.name] is active: the CDN config did not validate and browser assets are served by DreamDaemon")
		return
	log_asset("Asset transport: [transport.name] (config: [configured]), browser assets are served by DreamDaemon")

/datum/controller/subsystem/assets/Initialize(timeofday)
	// Construct explicitly early assets first. get_asset_datum() is the
	// synchronous contract; load_asset_datum() below only registers lazy work.
	for(var/type in typesof(/datum/asset))
		var/datum/asset/A = type
		if (type == initial(A._abstract) || !initial(A.early))
			continue
		get_asset_datum(type)

	for(var/type in typesof(/datum/asset))
		var/datum/asset/A = type
		if (type == initial(A._abstract) || initial(A.early))
			continue
		load_asset_datum(type)

	transport.Initialize(cache)

	// Повтор строки из OnConfigLoad: конфиг грузится до SetupLogs, поэтому там она
	// уходит в config_error.log, а asset.log раунда обязан отвечать на вопрос
	// "чем раздавали ассеты" сам по себе.
	log_active_transport()
	SSblackbox.record_feedback("tally", "resource_delivery", 1, istype(transport, /datum/asset_transport/webroot) ? "assets_webroot" : "assets_dreamdaemon")

	..()
