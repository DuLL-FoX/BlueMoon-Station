/// Сколько раз за раунд глушение внешних адресов снимается автоматически. Дальше оно
/// держится до конца раунда: раздача, отваливающаяся снова и снова, - это уже не
/// разовый сбой, а мигание медиа между HTTP и DreamDaemon с парой сообщений админам
/// на каждый цикл.
#define BM_LOBBY_MEDIA_MAX_AUTO_RESTORES 2

SUBSYSTEM_DEF(title_bm)
	name = "BlueMoon Title Screen"
	flags = SS_NO_FIRE
	init_order = INIT_ORDER_TITLE - 1

	var/current_image
	var/list/sfw_images = list()
	var/list/nsfw_images = list()
	var/lobby_html = ""
	var/current_notice
	var/loading_image = BM_LOBBY_LOADING_GIF
	var/current_video_payload
	var/cached_static_html = ""
	var/cached_js_url = ""           // URL JS-библиотеки — вычисляется один раз в _build_static_html
	var/cached_notice_js = ""        // JS-вызов для текущего объявления — кешируется в set_notice
	var/current_sfw_image
	var/current_nsfw_image
	/// Local source path -> content-addressed HTTP URL, generated during deploy.
	var/list/external_media_urls = list()
	/// Вид медиа (loading/background/audio/script) -> сколько раз клиенты не смогли
	/// забрать его по HTTP и попросили раздачу через DreamDaemon.
	var/list/media_fallback_counts = list()
	/// Вид медиа -> ckey игроков, у которых это случилось. Массовость меряем по
	/// игрокам, повторы одного клиента ничего не говорят о внешней раздаче.
	var/list/media_fallback_players = list()
	/// Виды, по которым админам уже сказали, что фолбэк массовый.
	var/list/media_fallback_alerted = list()
	/// TRUE - внешние адреса медиа временно не выдаются, всё идёт через DreamDaemon.
	/// Ставится массовым фолбэком по игрокам или вердиктом SScdn_probe, снимается
	/// успешной пробой. Если проба выключена конфигом, глушение живёт до конца раунда:
	/// сервер не может сам узнать, что раздача поднялась.
	var/external_media_suppressed = FALSE
	/// Из-за чего заглушили - уходит в отчёт о доставке ресурсов.
	var/external_media_suppress_reason
	/// Адрес, которым проба обязана доказать, что чинить больше нечего. Живая
	/// загрузочная картинка ничего не говорит про пропавший с раздачи трек.
	var/external_media_suppress_probe_url
	/// Путь медиа, на котором споткнулись последним - из него и берётся адрес пробы.
	var/last_failed_media_path
	/// Сколько раз за раунд глушение уже снимали автоматически.
	var/external_media_auto_restores = 0

/// Перечитывает BM_LOBBY_HTML_FILE с диска и пересылает свежий HTML всем игрокам в лобби.
/// Возвращает количество обновлённых клиентов.
/datum/controller/subsystem/title_bm/proc/reload_lobby_html()
	if(fexists(BM_LOBBY_HTML_FILE))
		lobby_html = _parse_lobby_html(file2text(BM_LOBBY_HTML_FILE))
	else
		lobby_html = ""
		log_game("[name]: файл лобби [BM_LOBBY_HTML_FILE] не найден — используется запасная преамбула из кода.")
	var/refreshed = 0
	for(var/mob/dead/new_player/player as anything in GLOB.new_player_list)
		if(!player.client)
			continue
		INVOKE_ASYNC(player, TYPE_PROC_REF(/mob/dead/new_player, bm_update_lobby_html))
		refreshed++
	return refreshed

/datum/controller/subsystem/title_bm/proc/_parse_lobby_html(full_html)
	var/head_end = findtext(full_html, "</head>")
	var/search_from = head_end ? head_end : 1
	var/body_pos = findtext(full_html, "<body", search_from)
	if(body_pos)
		var/tag_end = findtext(full_html, ">", body_pos)
		return tag_end ? copytext(full_html, 1, tag_end + 1) : full_html
	return full_html

/datum/controller/subsystem/title_bm/Initialize()
	if(fexists(BM_LOBBY_HTML_FILE))
		lobby_html = _parse_lobby_html(file2text(BM_LOBBY_HTML_FILE))
	else
		lobby_html = ""
		log_game("[name]: файл лобби [BM_LOBBY_HTML_FILE] не найден — используется запасная преамбула из кода.")

	_load_external_media_manifest()
	_load_title_images()

	if(fexists(loading_image))
		// Keep the path lazy. HTTP delivery needs the original path as a manifest
		// key; local fallback calls fcopy_rsc only if a client actually needs it.
		loading_image = bm_normalize_lobby_media_path(loading_image)
	else
		log_game("[name]: Файл загрузочного GIF '[loading_image]' не найден. Фон лобби будет пустым до подбора картинки.")
		loading_image = null
	current_image = loading_image || BM_LOBBY_DEFAULT_IMAGE

	RegisterSignal(SSticker, COMSIG_TICKER_ENTER_PREGAME, PROC_REF(_on_enter_pregame))
	RegisterSignal(SSticker, COMSIG_TICKER_ENTER_SETTING_UP, PROC_REF(_on_enter_setting_up))

	_build_static_html()

	initialized = TRUE
	return SS_INIT_SUCCESS

/datum/controller/subsystem/title_bm/Destroy()
	UnregisterSignal(SSticker, list(COMSIG_TICKER_ENTER_PREGAME, COMSIG_TICKER_ENTER_SETTING_UP))
	sfw_images = null
	nsfw_images = null
	current_sfw_image = null
	current_nsfw_image = null
	cached_static_html = ""
	cached_js_url = ""
	cached_notice_js = ""
	external_media_urls = null
	return ..();

/datum/controller/subsystem/title_bm/Recover()
	current_image         = SStitle_bm.current_image
	loading_image         = SStitle_bm.loading_image
	sfw_images            = SStitle_bm.sfw_images
	nsfw_images           = SStitle_bm.nsfw_images
	current_notice        = SStitle_bm.current_notice
	if(fexists(BM_LOBBY_HTML_FILE))
		lobby_html = _parse_lobby_html(file2text(BM_LOBBY_HTML_FILE))
	else
		lobby_html = SStitle_bm.lobby_html
	cached_static_html      = SStitle_bm.cached_static_html
	cached_js_url           = SStitle_bm.cached_js_url
	cached_notice_js        = SStitle_bm.cached_notice_js
	current_sfw_image   = SStitle_bm.current_sfw_image
	current_nsfw_image  = SStitle_bm.current_nsfw_image
	external_media_urls = SStitle_bm.external_media_urls
	media_fallback_counts  = SStitle_bm.media_fallback_counts
	media_fallback_players = SStitle_bm.media_fallback_players
	media_fallback_alerted = SStitle_bm.media_fallback_alerted
	external_media_suppressed         = SStitle_bm.external_media_suppressed
	external_media_suppress_reason    = SStitle_bm.external_media_suppress_reason
	external_media_suppress_probe_url = SStitle_bm.external_media_suppress_probe_url
	external_media_auto_restores      = SStitle_bm.external_media_auto_restores
	last_failed_media_path            = SStitle_bm.last_failed_media_path

/proc/bm_normalize_lobby_media_path(media)
	if(!istext(media))
		return null
	var/path = replacetext(media, "\\", "/")
	while(copytext(path, 1, 3) == "./")
		path = copytext(path, 3)
	return path

/datum/controller/subsystem/title_bm/proc/_load_external_media_manifest()
	external_media_urls = list()
	if(!fexists(BM_LOBBY_MEDIA_MANIFEST))
		return
	var/list/manifest
	try
		manifest = json_decode(file2text(BM_LOBBY_MEDIA_MANIFEST))
	catch(var/exception/error)
		log_game("[name]: не удалось прочитать [BM_LOBBY_MEDIA_MANIFEST]: [error]")
		return
	var/list/assets = manifest?["assets"]
	if(!islist(assets))
		log_game("[name]: [BM_LOBBY_MEDIA_MANIFEST] не содержит список assets.")
		return
	for(var/source_path in assets)
		var/normalized_path = bm_normalize_lobby_media_path(source_path)
		var/url = assets[source_path]
		if(!normalized_path || !istext(url))
			continue
		if(findtext(url, "http://") != 1 && findtext(url, "https://") != 1)
			continue
		external_media_urls[normalized_path] = url

/datum/controller/subsystem/title_bm/proc/get_external_media_url(media)
	// Заглушено - вызывающие видят "адреса нет" и уходят на локальную раздачу.
	// Отдавать адрес, про который уже известно, что он не отвечает, значит гонять
	// каждого игрока через таймаут браузера и обратный href на сервер.
	if(external_media_suppressed)
		return null
	return lookup_external_media_url(media)

/// Адрес медиа по его локальному пути, без оглядки на глушение.
/datum/controller/subsystem/title_bm/proc/lookup_external_media_url(media)
	var/path = bm_normalize_lobby_media_path(media)
	if(!path)
		return null
	return external_media_urls?[path]

/**
 * Адрес для активной пробы: намеренно мимо глушения - иначе снять его было бы нечем.
 *
 * Порядок предпочтения не косметика. Проба по произвольному живому адресу снимала бы
 * глушение, вызванное ОДНИМ пропавшим файлом: раздача поднята, картинка отвечает,
 * заглушение снято, счётчики обнулены - и следующие пять игроков снова спотыкаются
 * о тот же битый трек. Медиа мигало бы между HTTP и DreamDaemon каждый интервал пробы,
 * а админы получали бы по два сообщения за цикл. Поэтому сначала спрашиваем ровно тот
 * адрес, из-за которого заглушили, потом - последний споткнувшийся, и только если
 * спотыкаться ещё не о что, берём загрузочную картинку как проверку живости хоста.
 */
/datum/controller/subsystem/title_bm/proc/get_media_probe_url()
	if(!length(external_media_urls))
		return null
	if(external_media_suppress_probe_url)
		return external_media_suppress_probe_url
	var/failed_url = lookup_external_media_url(last_failed_media_path)
	if(failed_url)
		return failed_url
	var/loading_url = lookup_external_media_url(loading_image)
	if(loading_url)
		return loading_url
	return external_media_urls[external_media_urls[1]]

/// Перестаёт выдавать внешние адреса лобби-медиа. Возвращает TRUE, если состояние
/// изменилось - вызывающий по этому решает, говорить ли что-то админам сам.
/// probe_url - адрес, живой ответ которого будет считаться починкой; пустой означает
/// "возьми тот, на котором споткнулись".
/datum/controller/subsystem/title_bm/proc/suppress_external_media(reason, announce = TRUE, probe_url)
	if(external_media_suppressed)
		return FALSE
	var/verification_url = probe_url || get_media_probe_url()
	external_media_suppressed = TRUE
	external_media_suppress_reason = reason
	external_media_suppress_probe_url = verification_url
	log_asset("Lobby media: внешняя раздача заглушена ([reason]), медиа идёт через DreamDaemon; проверять будем [verification_url || "нечем"]")
	if(announce)
		message_admins("Лобби: внешние адреса медиа больше не выдаём ([reason]). Картинки и музыка идут через DreamDaemon, пока проба не увидит раздачу живой.")
	return TRUE

/**
 * Возвращает выдачу внешних адресов. Зовётся только успешной пробой: без неё сервер
 * не может отличить поднявшуюся раздачу от лежащей.
 *
 * Снятий за раунд не больше BM_LOBBY_MEDIA_MAX_AUTO_RESTORES. Проба ходит по адресу
 * отказа, так что цикл "снял - снова заглушили" означает не разовый сбой, а раздачу,
 * которая отвечает через раз; держать медиа на DreamDaemon до конца раунда дешевле,
 * чем мигать им и сыпать админам по паре сообщений за цикл.
 */
/datum/controller/subsystem/title_bm/proc/restore_external_media(reason)
	if(!external_media_suppressed)
		return FALSE
	if(external_media_auto_restores >= BM_LOBBY_MEDIA_MAX_AUTO_RESTORES)
		return FALSE
	external_media_auto_restores++
	external_media_suppressed = FALSE
	external_media_suppress_reason = null
	external_media_suppress_probe_url = null
	// Порог массовости считаем заново: старые отметки относятся к прошлому отказу,
	// и без сброса второй отказ за раунд прошёл бы молча.
	media_fallback_alerted.Cut()
	media_fallback_players.Cut()
	log_asset("Lobby media: внешняя раздача снова отвечает ([reason]), медиа опять уходит по HTTP (снятие [external_media_auto_restores] из [BM_LOBBY_MEDIA_MAX_AUTO_RESTORES])")
	var/last_chance = external_media_auto_restores >= BM_LOBBY_MEDIA_MAX_AUTO_RESTORES
	message_admins("Лобби: внешняя раздача медиа снова отвечает ([reason]). Медиа опять уходит по HTTP.[last_chance ? " Следующий отказ за раунд снимать автоматически уже не будем." : ""]")
	return TRUE

/// Локальный путь того медиа, о которое споткнулся именно этот игрок. Вид называет
/// клиент, а путь берём со своей стороны: у каждого вида он свой и лежит либо в
/// подсистеме, либо на мобе игрока. "script" сюда не входит - он уезжает транспортом
/// ассетов, а не адресом из манифеста.
/datum/controller/subsystem/title_bm/proc/resolve_fallback_media_path(kind, mob/dead/new_player/player)
	switch(kind)
		if("loading")
			return loading_image
		if("background")
			return player?.bm_lobby_background_path
		if("audio")
			return player?.bm_lobby_music_path
	return null

/datum/controller/subsystem/title_bm/proc/get_local_media_resource(media)
	if(isnull(media))
		return null
	if(istext(media) && !fexists(media))
		return null
	return fcopy_rsc(media)

/// Считает срабатывания фолбэка лобби-медиа: браузер не смог забрать ресурс по
/// HTTP и попросил ту же картинку/музыку/скрипт у DreamDaemon.
/// В лог идут только первое срабатывание вида и переход через порог массовости -
/// строка на каждое событие при полном лобби была бы спамом, а вот "фон не
/// открылся сразу у пятерых" означает, что лежит внешняя раздача, а не сеть
/// одного игрока.
/datum/controller/subsystem/title_bm/proc/record_media_fallback(kind, mob/dead/new_player/player)
	if(!kind)
		return
	// Какой именно файл не приехал - иначе проба потом будет спрашивать не то.
	var/failed_path = resolve_fallback_media_path(kind, player)
	if(failed_path && lookup_external_media_url(failed_path))
		last_failed_media_path = failed_path
	media_fallback_counts[kind] += 1
	var/list/players_seen = media_fallback_players[kind] || list()
	var/player_ckey = player?.ckey
	if(player_ckey && !(player_ckey in players_seen))
		players_seen += player_ckey
	media_fallback_players[kind] = players_seen
	SSblackbox.record_feedback("tally", "resource_delivery_fallback", 1, "lobby_[kind]")
	if(media_fallback_counts[kind] == 1)
		log_asset("Lobby media fallback: [kind] is now served by DreamDaemon, a browser failed to fetch it over HTTP")
	if(media_fallback_alerted[kind])
		return
	if(length(players_seen) < BM_LOBBY_MEDIA_FALLBACK_ALERT_PLAYERS)
		return
	media_fallback_alerted[kind] = TRUE
	log_asset("WARNING: Lobby media fallback: [kind] failed over HTTP for [length(players_seen)] players ([media_fallback_counts[kind]] events), external media delivery looks down")
	// Глушим только по видам, которые действительно раздаются адресами из манифеста.
	// "script" уезжает транспортом ассетов, и его отказ говорит про CDN ассетов -
	// у того свой фолбэк, а лобби-медиа тут ни при чём.
	// Адрес проверки берём у ТОГО вида, который перешёл порог: снимать глушение должен
	// ответ от него, а не от любой живой картинки.
	var/static/list/manifest_media_kinds = list("loading", "background", "audio")
	var/suppressed = (kind in manifest_media_kinds) \
		&& suppress_external_media("массовый фолбэк [kind]", announce = FALSE, probe_url = lookup_external_media_url(failed_path))
	message_admins("Лобби: медиа ([kind]) не грузится по HTTP уже у [length(players_seen)] игроков - похоже, лежит внешняя раздача. \
		Ресурсы идут через DreamDaemon, лобби открывается медленнее.[suppressed ? " Внешние адреса больше не выдаём до успешной пробы." : ""]")

/// Сводка фолбэков лобби-медиа для админского верба.
/datum/controller/subsystem/title_bm/proc/get_media_fallback_summary()
	var/list/parts = list()
	for(var/kind in media_fallback_counts)
		var/list/players_seen = media_fallback_players[kind]
		parts += "[kind]: [media_fallback_counts[kind]] (игроков: [length(players_seen)])"
	if(!length(parts))
		parts += "срабатываний не было"
	if(external_media_suppressed)
		parts += "внешние адреса заглушены ([external_media_suppress_reason || "причина неизвестна"])"
	return parts.Join(", ")

/datum/controller/subsystem/title_bm/proc/_build_static_html()
	var/list/parts = list()
	parts += {"<img id=\"bm-bg\" class=\"bg\" src=\"loading_screen.gif\" alt=\"\">"}
	parts += {"<div id=\"bm-overlay\"></div>"}
	parts += {"<div id=\"bm-toasts\"></div>"}
	parts += {"<div id=\"bm-toggle-btn\" onclick=\"bmToggleSidebar()\" title=\"Свернуть/развернуть меню\">&#9654;</div>"}
	parts += {"<div id=\"bm-disclaimer-btn\" onclick=\"bmShowDisclaimer()\" title=\"Правила сервера\">&#9888;</div>"}
	cached_static_html = parts.Join("")

/datum/controller/subsystem/title_bm/proc/_load_images_from_dir(dir_path, list/target_list)
	if(!fexists(dir_path))
		return
	var/list/files = flist(dir_path)
	if(!islist(files))
		return
	for(var/filename in files)
		if(filename == "exclude" || filename == "blank.png")
			continue
		if(copytext(filename, length(filename)) == "/")
			continue
		var/lower = lowertext(filename)
		var/len = length(lower)
		var/is_image = (copytext(lower, len - 3) == ".png") \
			|| (copytext(lower, len - 3) == ".jpg") \
			|| (copytext(lower, len - 3) == ".gif") \
			|| (copytext(lower, len - 3) == ".dmi") \
			|| (copytext(lower, len - 4) == ".jpeg")
		if(!is_image)
			continue
		var/full_path = "[dir_path][filename]"
		// Store paths instead of eagerly copying the entire pool into dyn.rsc.
		target_list += bm_normalize_lobby_media_path(full_path)

/datum/controller/subsystem/title_bm/proc/_load_title_images()
	_load_images_from_dir(BM_LOBBY_IMAGES_SFW, sfw_images)
	_load_images_from_dir(BM_LOBBY_IMAGES_NSFW, nsfw_images)

/datum/controller/subsystem/title_bm/proc/get_image_for_player(show_nsfw = FALSE, show_admin_bg = TRUE)
	if(loading_image && current_image == loading_image)
		return loading_image
	if(show_admin_bg && current_image)
		return current_image
	if(show_nsfw && current_nsfw_image)
		return current_nsfw_image
	if(current_sfw_image)
		return current_sfw_image
	// fallback: если кеш ещё не заполнен — выбрать случайно
	var/list/pool = show_nsfw && LAZYLEN(nsfw_images) ? nsfw_images : sfw_images
	if(!LAZYLEN(pool))
		return BM_LOBBY_DEFAULT_IMAGE
	return pick(pool)

/datum/controller/subsystem/title_bm/proc/_rotate_current_images()
	if(LAZYLEN(sfw_images))
		current_sfw_image = pick(sfw_images)
	if(LAZYLEN(nsfw_images))
		current_nsfw_image = pick(nsfw_images)
	else
		current_nsfw_image = current_sfw_image

/datum/controller/subsystem/title_bm/proc/set_video(payload)
	current_video_payload = payload
	current_image = null
	for(var/mob/dead/new_player/player as anything in GLOB.new_player_list)
		if(!player.bm_lobby_ready || !player.client)
			continue
		if(!player.client.prefs || player.client.prefs.bm_lobby_show_admin_bg)
			player.client << output(payload, "bm_lobby_browser:bm_set_background")

/datum/controller/subsystem/title_bm/proc/change_image(file_or_icon)
	current_video_payload = null
	if(file_or_icon)
		current_image = file_or_icon
	else
		current_image = null

	// Готовым — только меняем картинку через JS (без перезагрузки HTML → музыка не прерывается)
	// Не готовым — полный показ лобби с нуля
	for(var/mob/dead/new_player/player as anything in GLOB.new_player_list)
		if(player.spawning || player.new_character)
			continue
		if(player.bm_lobby_ready)
			INVOKE_ASYNC(player, TYPE_PROC_REF(/mob/dead/new_player, bm_push_background))
		else
			INVOKE_ASYNC(player, TYPE_PROC_REF(/mob/dead/new_player, bm_show_lobby))

/datum/controller/subsystem/title_bm/proc/show_to_all()
	for(var/mob/dead/new_player/player as anything in GLOB.new_player_list)
		if(player.spawning || player.new_character)
			continue
		INVOKE_ASYNC(player, TYPE_PROC_REF(/mob/dead/new_player, bm_show_lobby))

/datum/controller/subsystem/title_bm/proc/set_notice(notice_text)
	current_notice = notice_text ? sanitize_text(notice_text) : null
	// Кешируем escaped-версию для подстановки в _bm_build_html новых игроков
	var/escaped = ""
	if(current_notice)
		escaped = replacetext(current_notice, "\\", "\\\\")
		escaped = replacetext(escaped, "'", "\\'")
		escaped = replacetext(escaped, "\n", "\\n")
		cached_notice_js = "bm_show_notice('[escaped]');"
	else
		cached_notice_js = ""
	var/toast_type = current_notice ? "'error'" : "'info'"
	for(var/mob/dead/new_player/player as anything in GLOB.new_player_list)
		if(!player.bm_lobby_ready || !player.client)
			continue
		player.client << output("'[escaped]',[toast_type]", "bm_lobby_browser:bm_show_notice")

/datum/controller/subsystem/title_bm/proc/update_character_name(mob/dead/new_player/user, name)
	if(!(istype(user) && user.bm_lobby_ready && user.client))
		return
	user.client << output(name, "bm_lobby_browser:bm_update_character")

/datum/controller/subsystem/title_bm/proc/_get_player_counts()
	var/ready = 0
	for(var/mob/dead/new_player/np as anything in GLOB.new_player_list)
		if(QDELETED(np))
			continue
		if(np.ready)
			ready++
	return list(length(GLOB.clients), length(GLOB.new_player_list), ready)

/// Вызывается при изменении ready-статуса игрока. Пересчитывает счётчик и рассылает payload.
/datum/controller/subsystem/title_bm/proc/on_player_ready_change(delta)
	update_player_counts_all()

/datum/controller/subsystem/title_bm/proc/_build_counts_payload()
	var/list/counts = _get_player_counts()
	var/timer_s = (SSticker?.timeLeft > 0) ? round(SSticker.timeLeft / 10) : -1
	var/is_pregame = (!SSticker || SSticker.current_state <= GAME_STATE_PREGAME) ? 1 : 0
	return "[counts[1]],[counts[2]],[counts[3]],[timer_s],[is_pregame]"

/datum/controller/subsystem/title_bm/proc/push_player_count_to(mob/dead/new_player/player)
	if(!(istype(player) && player.bm_lobby_ready && player.client))
		return
	player.client << output(_build_counts_payload(), "bm_lobby_browser:bm_update_counts")

/datum/controller/subsystem/title_bm/proc/update_player_counts_all()
	var/payload = _build_counts_payload()
	for(var/mob/dead/new_player/player as anything in GLOB.new_player_list)
		if(QDELETED(player) || !player.bm_lobby_ready || !player.client)
			continue
		player.client << output(payload, "bm_lobby_browser:bm_update_counts")

/datum/controller/subsystem/title_bm/proc/_on_enter_pregame()
	SIGNAL_HANDLER
	_rotate_current_images()  // выбираем случайную картинку один раз при старте прегейма
	change_image(null)
	if(SSticker?.login_music)
		for(var/mob/dead/new_player/player as anything in GLOB.new_player_list)
			if(!player.bm_lobby_ready || !player.client || player.bm_lobby_music_path)
				continue
			INVOKE_ASYNC(player.client, TYPE_PROC_REF(/client, bm_push_lobby_music))

/datum/controller/subsystem/title_bm/proc/_on_enter_setting_up()
	SIGNAL_HANDLER
	for(var/mob/dead/new_player/player as anything in GLOB.new_player_list)
		if(player.spawning || player.new_character || !player.client)
			continue
		if(player.bm_lobby_ready)
			INVOKE_ASYNC(player, TYPE_PROC_REF(/mob/dead/new_player, bm_push_menu_update), TRUE)
		else
			INVOKE_ASYNC(player, TYPE_PROC_REF(/mob/dead/new_player, bm_update_lobby_html))
	INVOKE_ASYNC(src, PROC_REF(update_player_counts_all))

#undef BM_LOBBY_MEDIA_MAX_AUTO_RESTORES
