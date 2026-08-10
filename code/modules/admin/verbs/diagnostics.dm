/proc/show_air_status_to(turf/target, mob/user)
	var/datum/gas_mixture/env = target.return_air()
	var/burning = FALSE
	if(isopenturf(target))
		var/turf/open/T = target
		if(T.active_hotspot)
			burning = TRUE

	var/list/lines = list("<span class='adminnotice'>[AREACOORD(target)]: [env.return_temperature()] K ([env.return_temperature() - T0C] C), [env.return_pressure()] kPa[(burning)?(", <font color='red'>burning</font>"):(null)]</span>")
	for(var/id in env.get_gases())
		var/moles = env.get_moles(id)
		if (moles >= 0.00001)
			lines += "[GLOB.gas_data.names[id]]: [moles] mol"
	to_chat(usr, lines.Join("\n"))

/client/proc/air_status(turf/target)
	set category = "Debug.9) Debug Verbs"
	set name = "Display Air Status"

	if(!isturf(target))
		return
	show_air_status_to(target, usr)
	SSblackbox.record_feedback("tally", "admin_verb", 1, "Show Air Status") //If you are copy-pasting this, ensure the 2nd parameter is unique to the new proc!

/client/proc/radio_report()
	set category = "Debug.9) Debug Verbs"
	set name = "Radio report"

	var/output = "<b>Radio Report</b><hr>"
	for (var/fq in SSradio.frequencies)
		output += "<b>Freq: [fq]</b><br>"
		var/datum/radio_frequency/fqs = SSradio.frequencies[fq]
		if (!fqs)
			output += "&nbsp;&nbsp;<b>ERROR</b><br>"
			continue
		for (var/filter in fqs.devices)
			var/list/f = fqs.devices[filter]
			if (!f)
				output += "&nbsp;&nbsp;[filter]: ERROR<br>"
				continue
			output += "&nbsp;&nbsp;[filter]: [f.len]<br>"
			for (var/device in f)
				if (istype(device, /atom))
					var/atom/A = device
					output += "&nbsp;&nbsp;&nbsp;&nbsp;[device] ([AREACOORD(A)])<br>"
				else
					output += "&nbsp;&nbsp;&nbsp;&nbsp;[device]<br>"

	var/datum/browser/popup = new(usr, "radioreport", "Radio Report")
	popup.set_content(output)
	popup.open(FALSE)
	SSblackbox.record_feedback("tally", "admin_verb", 1, "Show Radio Report") //If you are copy-pasting this, ensure the 2nd parameter is unique to the new proc!

/client/proc/reload_admins()
	set name = "Reload Admins"
	set category = "Admin"

	if(!src.holder)
		return

	var/confirm = alert(src, "Are you sure you want to reload all admins?", "Confirm", "Yes", "No")
	if(confirm !="Yes")
		return

	load_admins()
	SSblackbox.record_feedback("tally", "admin_verb", 1, "Reload All Admins") //If you are copy-pasting this, ensure the 2nd parameter is unique to the new proc!
	message_admins("[key_name_admin(usr)] manually reloaded admins")

/client/proc/toggle_cdn()
	set name = "Toggle CDN"
	set category = "Server"
	var/static/admin_disabled_cdn_transport = null
	if (alert(usr, "Переключить раздачу браузерных ассетов через CDN?", "Подтверждение", "Да", "Нет") != "Да")
		return
	// Состояние берём с фактического транспорта, а не из конфига: после тихого
	// фолбэка конфиг продолжает показывать webroot, и верб докладывал админу об
	// отключении CDN, который к тому моменту уже был отключён сам собой.
	var/cdn_active = istype(SSassets.transport, /datum/asset_transport/webroot)
	var/configured_transport = CONFIG_GET(string/asset_transport)
	if (cdn_active)
		admin_disabled_cdn_transport = configured_transport
		CONFIG_SET(string/asset_transport, "simple")
		SSassets.OnConfigLoad()
		SSassets.transport.dont_mutate_filenames = TRUE
		// Инвалидация строго после dont_mutate_filenames: пересборка css
		// спрайтшитов обязана видеть окончательную форму URL нового транспорта.
		// Без неё выданные CDN-адреса живут в кешах ассетов и открытых окнах до
		// конца раунда, и переключение "помогает" только новым подключениям.
		SSassets.invalidate_asset_urls()
		message_admins("[key_name_admin(usr)] отключил раздачу ассетов через CDN. Ассеты идут через сервер.")
		log_admin("[key_name(usr)] disabled the CDN asset transport")
		return

	var/transport_to_restore = admin_disabled_cdn_transport || (configured_transport == "webroot" ? configured_transport : null)
	if (!transport_to_restore)
		to_chat(usr, "<span class='adminnotice'>CDN не настроен: ассеты и так раздаёт сервер ([SSassets.transport.name]).</span>")
		if (alert(usr, "CDN не включён. Если проблемы именно с ассетами, можно попробовать отключить искажение имён файлов.", "CDN не включён", "Отключить искажение имён", "Отмена") == "Отключить искажение имён")
			SSassets.transport.dont_mutate_filenames = !SSassets.transport.dont_mutate_filenames
			// Флаг меняет форму URL каждого ассета: css спрайтшитов и кеши
			// адресов собраны под старую форму и без инвалидации разъедутся с
			// именами, под которыми файлы теперь уезжают клиентам.
			SSassets.invalidate_asset_urls()
			message_admins("[key_name_admin(usr)] [(SSassets.transport.dont_mutate_filenames ? "отключил" : "включил обратно")] искажение имён файлов ассетов")
			log_admin("[key_name(usr)] [(SSassets.transport.dont_mutate_filenames ? "disabled" : "re-enabled")] asset filename transforms")
		return

	if (!admin_disabled_cdn_transport)
		to_chat(usr, "<span class='adminnotice'>CDN никто не выключал вручную: транспорт сорвался сам ([GLOB.asset_transport_fallbacks] раз, последняя причина: [GLOB.asset_transport_fallback_reason || "неизвестна"]). Пробуем поднять его заново.</span>")
	CONFIG_SET(string/asset_transport, transport_to_restore)
	admin_disabled_cdn_transport = null
	SSassets.OnConfigLoad()
	if (istype(SSassets.transport, /datum/asset_transport/webroot))
		// Транспорт реально сменился - локальные адреса в кешах и css надо
		// пересобрать под CDN. В ветке неудачи транспорт остался прежним, там
		// инвалидировать нечего.
		SSassets.invalidate_asset_urls()
		message_admins("[key_name_admin(usr)] включил раздачу ассетов через CDN.")
		log_admin("[key_name(usr)] re-enabled the CDN asset transport")
		return
	message_admins("[key_name_admin(usr)] попытался включить CDN, но транспорт не поднялся: ассеты по-прежнему раздаёт сервер. Смотрите asset.log и ASSET_CDN_URL/ASSET_CDN_WEBROOT.")
	log_admin("[key_name(usr)] failed to re-enable the CDN asset transport")

/**
 * Переключает внешнюю выдачу .rsc на лету.
 *
 * Адреса версионного архива зашиты в сборку деплоем, поэтому исчезнувший с раздачи
 * архив без этого верба лечился бы перекомпиляцией: клиент за клиентом получал бы
 * адрес, по которому ничего нет, и висел на "Downloading resources".
 */
/client/proc/toggle_external_rsc()
	set name = "Toggle External RSC"
	set category = "Server"

	if(!src.holder)
		return

	var/turning_off = GLOB.external_rsc_delivery_enabled
	var/prompt = turning_off \
		? "Отключить внешнюю выдачу .rsc? Входящие клиенты будут тянуть архив ресурсов с сервера - медленнее, но без зависимости от внешней раздачи." \
		: "Включить внешнюю выдачу .rsc обратно?"
	if(alert(usr, prompt, "Переключить внешнюю выдачу RSC", "Да", "Нет") != "Да")
		return

	GLOB.external_rsc_delivery_enabled = !turning_off
	// Уже вошедшим клиентам адрес выдан на входе и не меняется - говорим об этом прямо,
	// иначе первый же "у меня всё равно не грузится" уведёт разбор не туда.
	message_admins("[key_name_admin(usr)] [turning_off ? "отключил" : "включил"] внешнюю выдачу .rsc. \
		Действует на новые подключения; уже вошедшие клиенты доигрывают с прежним источником.")
	log_admin("[key_name(usr)] [turning_off ? "disabled" : "enabled"] external RSC delivery")
	SSblackbox.record_feedback("tally", "admin_verb", 1, "Toggle External RSC") //If you are copy-pasting this, ensure the 2nd parameter is unique to the new proc!

/// Со скольких затронутых игроков локальный фолбэк статбраузера перестаёт быть
/// единичным случаем и заслуживает тревожного цвета.
#define STATBROWSER_FALLBACK_ALERT_PLAYERS 5

/client/proc/resource_delivery_report()
	set name = "Show Resource Delivery"
	set category = "Server"

	if (!src.holder)
		return

	var/list/lines = list("<b>Доставка ресурсов</b>")

	var/configured_transport = CONFIG_GET(string/asset_transport) || "simple"
	var/cdn_active = istype(SSassets.transport, /datum/asset_transport/webroot)
	lines += "Браузерные ассеты (TGUI, шрифты, статпанель): <b>[cdn_active ? "гибрид CDN + DreamDaemon" : "сервер (DreamDaemon)"]</b> - [SSassets.transport.name], в конфиге: [configured_transport]"
	if (cdn_active)
		var/datum/asset_transport/webroot/webroot_transport = SSassets.transport
		lines += "&nbsp;&nbsp;URL: [CONFIG_GET(string/asset_cdn_url)]"
		lines += "&nbsp;&nbsp;Read-only webroot: [CONFIG_GET(string/asset_cdn_webroot)]"
		lines += "&nbsp;&nbsp;Ассетов без build-копии направлено через сервер: [webroot_transport.local_asset_count]"
	else if (configured_transport == "webroot")
		lines += "&nbsp;&nbsp;<span class='danger'>Конфиг требует webroot, но транспорт им не стал: CDN не прошёл проверку или сорвался.</span>"
	if (GLOB.asset_transport_fallbacks)
		lines += "&nbsp;&nbsp;Срывов на раздачу через сервер: [GLOB.asset_transport_fallbacks], последний [DisplayTimeText(world.time - GLOB.asset_transport_fallback_time)] назад ([GLOB.asset_transport_fallback_reason || "причина неизвестна"])"
	else
		lines += "&nbsp;&nbsp;Срывов на раздачу через сервер за раунд: нет"

	if (GLOB.statbrowser_local_fallbacks)
		// Единичный фолбэк - штатная работа страховки: чаще всего это залипший
		// panel_ready-мост у одного клиента, а не авария раздачи. Красным кричим
		// только когда локально открываться пришлось многим.
		var/fallback_players = length(GLOB.statbrowser_local_fallback_players)
		var/fallback_line = "Статбраузер пришлось открывать локально: [GLOB.statbrowser_local_fallbacks] раз(а), игроков [fallback_players]"
		if (fallback_players >= STATBROWSER_FALLBACK_ALERT_PLAYERS)
			lines += "&nbsp;&nbsp;<span class='danger'>[fallback_line]</span>"
		else
			lines += "&nbsp;&nbsp;[fallback_line]"

#if (PRELOAD_RSC != 0)
	lines += "Игровой RSC: <b>сервер (DreamDaemon)</b> - сборка с PRELOAD_RSC != 0, внешние адреса не используются"
#else
	if (!GLOB.external_rsc_delivery_enabled)
		lines += "Игровой RSC: <b>сервер (DreamDaemon)</b> - внешняя выдача выключена (верб «Toggle External RSC» или EXTERNAL_RSC_DELIVERY 0)"
	else if (!GLOB.external_rsc_source_logged)
		lines += "Игровой RSC: источник ещё не определён (ни один клиент не запрашивал ресурсы)"
	else if (!length(GLOB.external_rsc_url_list))
		lines += "Игровой RSC: <b>сервер (DreamDaemon)</b> - внешних адресов нет"
	else
		lines += "Игровой RSC: <b>[length(GLOB.external_rsc_url_list)] внешн. адрес(ов)</b>, источник: [GLOB.external_rsc_from_deployment ? "зашиты в этот DMB деплоем" : "конфиг EXTERNAL_RSC_URLS"]"
		for (var/url in GLOB.external_rsc_url_list)
			lines += "&nbsp;&nbsp;[url]"
#endif

	if (SStitle_bm)
		lines += "Медиа лобби: опубликовано внешних адресов - [length(SStitle_bm.external_media_urls)]"
		lines += "&nbsp;&nbsp;Фолбэки на раздачу через сервер: [SStitle_bm.get_media_fallback_summary()]"
	else
		lines += "Медиа лобби: подсистема лобби не запущена"

	if (SScdn_probe)
		lines += SScdn_probe.get_probe_report_lines()
	else
		lines += "Активная проба: подсистема не запущена"

	var/stage_summary = build_connection_stage_summary()
	if (stage_summary)
		lines += stage_summary

	// Отдельным вызовом: сводка по этапам считает ЗАКРЫТЫЕ соединения и на здоровом
	// раунде пуста, а тайминги считаются по живым клиентам и есть всегда. Раньше они
	// были частью строки выше и до первого отключившегося верб их не показывал вовсе.
	var/timing_summary = build_resource_stage_timing_summary()
	if (timing_summary)
		lines += timing_summary

	to_chat(usr, "<span class='adminnotice'>[lines.Join("<br>")]</span>")
	log_admin("[key_name(usr)] посмотрел отчёт о доставке ресурсов")
	SSblackbox.record_feedback("tally", "admin_verb", 1, "Show Resource Delivery") //If you are copy-pasting this, ensure the 2nd parameter is unique to the new proc!

#undef STATBROWSER_FALLBACK_ALERT_PLAYERS
