/datum/asset/simple/namespaced/bluemoon_statbrowser
	parents = list(
		"statbrowser.html" = 'html/statbrowser.html',
	)

/datum/asset/simple/namespaced/bluemoon_tooltip
	assets = list(
		"tooltip-jquery.min.js" = 'html/jquery/jquery.min.js',
		"tooltip-SpaceMono.ttf" = 'interface/fonts/SpaceMono.ttf',
	)
	parents = list(
		"tooltip.html" = 'code/modules/tooltip/tooltip.html',
	)

/// Сколько раз за раунд статбраузер пришлось переоткрывать локально, потому что
/// окно не приехало по внешнему адресу. Ноль здесь - единственный ответ на вопрос
/// "панель у всех поднялась?": сам клиент про неприехавшее окно молчит.
GLOBAL_VAR_INIT(statbrowser_local_fallbacks, 0)
/// Сколько РАЗНЫХ ckey это задело. Один игрок с плохой сетью - не событие.
GLOBAL_LIST_EMPTY(statbrowser_local_fallback_players)

/client/proc/load_bluemoon_statbrowser()
	var/datum/asset/simple/namespaced/bluemoon_statbrowser/statbrowser_assets = get_asset_datum(/datum/asset/simple/namespaced/bluemoon_statbrowser)
	// Наружу адрес окна ведёт только при webroot-транспорте. Запоминаем это здесь:
	// к моменту check_panel_loaded() транспорт мог уже сорваться на DreamDaemon, а
	// клиент всё равно держит выданный ему http-адрес.
	var/datum/asset_transport/webroot/webroot_transport = SSassets.transport
	statbrowser_served_externally = istype(webroot_transport) && webroot_transport.asset_is_external(statbrowser_assets.assets["statbrowser.html"])
	statbrowser_assets.send(src)
	src << browse(statbrowser_assets.get_htmlloader("statbrowser.html"), "window=statbrowser")

/**
 * Открывает статбраузер содержимым окна, мимо транспорта ассетов.
 *
 * Штатный путь отдаёт клиенту загрузчик с адресом ассета, и при webroot-транспорте
 * этот адрес ведёт на внешнюю раздачу. Если она лежит, окно не поднимается вовсе:
 * statbrowser_ready не выставляется, статпанель не приезжает, а preload_resources_when_ui_ready()
 * ждёт готовности интерфейса, которой уже не будет. Здесь html уходит прямо в окно
 * через DreamDaemon - единственный путь, который от внешней раздачи не зависит.
 */
/client/proc/load_local_statbrowser()
	var/was_served_externally = statbrowser_served_externally
	statbrowser_served_externally = FALSE
	if(!statbrowser_local_fallback)
		statbrowser_local_fallback = TRUE
		GLOB.statbrowser_local_fallbacks++
		if(!(ckey in GLOB.statbrowser_local_fallback_players))
			GLOB.statbrowser_local_fallback_players += ckey
		// Молчание панели НЕ доказывает, что виновата внешняя раздача: штатная причина
		// тут - залипший panel_ready-мост, и окно могло приехать целым. Пишем ровно то,
		// что знаем, плюс откуда его выдавали, - иначе счётчик читается как счётчик
		// падений CDN и уводит разбор не туда.
		log_asset("Statbrowser fallback: [ckey] - панель не доложила о загрузке за [DisplayTimeText(STATBROWSER_LOAD_TIMEOUT)], пробуем локально через DreamDaemon (окно выдавалось [was_served_externally ? "внешним адресом" : "локально"])")
		SSblackbox.record_feedback("tally", "resource_delivery_fallback", 1, "statbrowser")
	src << browse(file('html/statbrowser.html'), "window=statbrowser")
