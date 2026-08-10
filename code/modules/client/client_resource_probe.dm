/**
 * # Клиентская проба внешней раздачи ресурсов
 *
 * Зачем она нужна и чего не может серверная проба - в шапке блока
 * CLIENT_DELIVERY_PROBE_* в code/__BLUEMOONCODE/_DEFINES/client_resources.dm.
 *
 * Здесь - серверная половина: кому и когда отправляем запрос, как принимаем ответ
 * и что с ним делаем. Отчёт приезжает из WebView, то есть он НЕДОВЕРЕННЫЙ, и
 * обращаемся мы с ним ровно так же, как record_browser_latency() обращается с
 * отчётом о задержке: кулдаун на клиента, только известные состояния, числа
 * обрезаны по здравому пределу.
 *
 * Проба ничего не выключает и ничего не показывает игроку. Она двигает capability,
 * пишет строку в asset.log, событие в client_latency.jsonl и счётчик в blackbox.
 * Решение «раздаём через DreamDaemon» по-прежнему принимает человек вербом
 * «Toggle External RSC»: клиентский отчёт подделывается тривиально, а цена
 * ошибочного переключения - канал сервера на каждом входе до конца раунда.
 *
 * Отдельная оговорка про точность: WebView и DreamSeeker - разные HTTP-клиенты в
 * одном процессе. Общий у них сетевой стек Windows, системный прокси и DNS, то есть
 * ровно то, что ломается у игрока с «не грузятся ресурсы». Не общие у них
 * политика CORS и правило mixed content, поэтому провал пробы - это ПОВОД
 * посмотреть на клиента, а не доказательство, что архив к нему не приехал.
 */

/// Скольким клиентам за раунд отправили пробу.
GLOBAL_VAR_INIT(external_delivery_probes_requested, 0)
/// Сколько клиентов подтвердили, что выданный им внешний адрес доезжает.
GLOBAL_VAR_INIT(external_delivery_probes_ok, 0)
/// Сколько отчитались о том, что хост ответил, но отказом по файлу.
GLOBAL_VAR_INIT(external_delivery_probes_degraded, 0)
/// Сколько отчитались о полной недоступности адреса.
GLOBAL_VAR_INIT(external_delivery_probes_failed, 0)
/// ckey -> причина последнего провала. Одно «недоступно» - это чья-то плохая сеть,
/// а десять с одинаковой причиной - это уже раздача, и без имён их не различить.
GLOBAL_LIST_EMPTY(external_delivery_probe_failures)

/// Сколько провалившихся клиентов показывать в админском отчёте поимённо.
#define CLIENT_DELIVERY_PROBE_REPORT_FAILURES 5

/// Отправляет запрос пробы в панель. Живёт на панели, а не на клиенте, чтобы окно
/// оставалось её внутренним делом, как у request_telemetry().
/datum/tgui_panel/proc/send_external_delivery_probe(list/targets, generation)
	window.send_message("resourceProbe/request", list(
		"generation" = generation,
		"timeoutMs" = CLIENT_DELIVERY_PROBE_REQUEST_TIMEOUT * 100,
		"targets" = targets,
	))

/// Известна ли нам такая цель. Отдельным проком - его же зовёт приём отчёта.
/proc/is_external_delivery_probe_target(target_key)
	return target_key == CLIENT_DELIVERY_PROBE_TARGET_RSC || target_key == CLIENT_DELIVERY_PROBE_TARGET_ASSETS

/**
 * Чистое отображение отчёта браузера в состояние capability.
 *
 * Вынесено из /client, чтобы правило читалось и проверялось без живого клиента.
 * Возвращает null для незнакомого состояния - такой результат отбрасывается,
 * а не трактуется на всякий случай как провал.
 *
 * http_error - именно DEGRADED, а не FAILED: сеть до раздачи у клиента есть,
 * проблема на стороне хоста, и её видит серверная проба. Смешивать эти два случая
 * в одном состоянии значило бы обвинять сеть игрока в чужой ошибке.
 */
/proc/external_delivery_probe_state(result_status)
	switch(result_status)
		if(CLIENT_DELIVERY_PROBE_OK)
			return CLIENT_CAPABILITY_READY
		if(CLIENT_DELIVERY_PROBE_HTTP_ERROR)
			return CLIENT_CAPABILITY_DEGRADED
		if(CLIENT_DELIVERY_PROBE_BLOCKED, CLIENT_DELIVERY_PROBE_TIMEOUT)
			return CLIENT_CAPABILITY_FAILED
	return null

/// Какой capability принадлежит цель.
/proc/external_delivery_probe_capability(target_key)
	if(target_key == CLIENT_DELIVERY_PROBE_TARGET_RSC)
		return CLIENT_CAPABILITY_RSC
	if(target_key == CLIENT_DELIVERY_PROBE_TARGET_ASSETS)
		return CLIENT_CAPABILITY_ASSET_CACHE
	return null

/// Обрезает длительность из недоверенного источника. Отрицательное и нечисловое
/// значит «клиент не замерил», а не «ноль миллисекунд».
/proc/external_delivery_probe_duration_ms(value)
	if(!isnum(value) || value < 0)
		return null
	return round(min(value, CLIENT_DELIVERY_PROBE_MAX_REPORTED_MS), 1)

/// Обрезает HTTP-статус. Ноль у непрозрачного ответа штатен: браузер по устройству
/// не показывает статус запроса, отправленного без CORS.
/proc/external_delivery_probe_http_status(value)
	if(!isnum(value) || value < 0 || value > 599)
		return 0
	return round(value, 1)

/// Текст ошибки от браузера уходит в лог и в отчёт админам, поэтому чистим его от
/// разметки и режем: дальше начинается стектрейс, которому в строке лога не место.
/// strip_html() режет по границе copytext, то есть отдаёт limit-1 символов - предел
/// поднят на единицу, чтобы дефайн означал ровно то, что написано в его имени.
/proc/external_delivery_probe_detail(value)
	if(!istext(value))
		return ""
	return strip_html(value, CLIENT_DELIVERY_PROBE_DETAIL_MAX_LENGTH + 1)

/// Короткая осмысленная причина для capability_reasons и лога.
/proc/external_delivery_probe_reason(result_status, http_status, duration_ms, detail)
	var/list/parts = list()
	switch(result_status)
		if(CLIENT_DELIVERY_PROBE_OK)
			// Ноль статуса у успеха означает непрозрачный ответ: адрес доехал, а
			// разбирать его нам не дали. Дописывать «(0)» в такую строку незачем.
			parts += (http_status ? "адрес доступен ([http_status])" : "адрес доступен")
		if(CLIENT_DELIVERY_PROBE_HTTP_ERROR)
			parts += (http_status ? "хост ответил [http_status]" : "хост ответил отказом")
		if(CLIENT_DELIVERY_PROBE_BLOCKED)
			parts += "адрес не открылся"
		if(CLIENT_DELIVERY_PROBE_TIMEOUT)
			parts += "нет ответа"
		else
			parts += "неизвестный результат"
	if(length(detail))
		parts += detail
	if(!isnull(duration_ms))
		parts += "[duration_ms]мс"
	return "проба клиента: [parts.Join(", ")]"

/// Худшее из двух состояний. Клиент в счётчиках раунда учитывается один раз, и
/// учитывать его надо по самой плохой цели: доступный статбраузер не отменяет
/// неприехавшего архива.
/proc/external_delivery_probe_worst_state(first_state, second_state)
	if(first_state == CLIENT_CAPABILITY_FAILED || second_state == CLIENT_CAPABILITY_FAILED)
		return CLIENT_CAPABILITY_FAILED
	if(first_state == CLIENT_CAPABILITY_DEGRADED || second_state == CLIENT_CAPABILITY_DEGRADED)
		return CLIENT_CAPABILITY_DEGRADED
	return first_state || second_state

/// Адреса, которые выданы ИМЕННО ЭТОМУ клиенту. Пустой список значит, что проверять
/// нечего: сборка без внешней раздачи, выключенная выдача или локальный транспорт.
/client/proc/collect_external_delivery_probe_targets()
	var/list/targets = list()
	// rsc_source_url ставит send_resources() и только когда адрес реально уехал
	// клиенту: выключенная вербом выдача оставляет его null.
	if(rsc_source_url)
		targets += list(list("key" = CLIENT_DELIVERY_PROBE_TARGET_RSC, "url" = rsc_source_url))
	// Тот же адрес, по которому ходит серверная проба: из всех опубликованных
	// ассетов статбраузер ломает раунд громче остальных.
	var/asset_url = SScdn_probe?.get_asset_probe_url()
	if(asset_url)
		targets += list(list("key" = CLIENT_DELIVERY_PROBE_TARGET_ASSETS, "url" = asset_url))
	return targets

/**
 * Просит панель проверить выданные этому клиенту внешние адреса.
 *
 * Ровно один раз за жизнь /client: набор адресов за подключение не меняется, а
 * повторная проба стоила бы лишнего запроса наружу у каждого, кто переоткрыл чат.
 *
 * Зовётся дважды - из конца send_resources() и из готовности панели, - потому что
 * порядок между ними не гарантирован: tgui_panel.initialize() стоит в /client/New()
 * ВЫШЕ send_resources(), а между ними успевают отработать SQL-запросы, которые
 * усыпляют New(). Тот из двух вызовов, который пришёл вторым, и отправляет пробу;
 * первый уходит ни с чем. Без этого клиент, чья панель поднялась раньше выдачи
 * ресурсов, навсегда терял бы из пробы главную цель - адрес .rsc.
 */
/client/proc/request_external_delivery_probe()
	if(external_delivery_probe_sent)
		return FALSE
	// Панели нет или она ещё не поднялась - молчим. Просить окно, которого нет,
	// значит отправить сообщение в очередь и получить ответ неизвестно когда.
	if(!tgui_panel?.is_ready())
		return FALSE
	var/datum/client_resource_session/session = ensure_resource_session()
	// send_resources() ещё не отработал: адрес .rsc клиенту не назначен, и проба
	// сейчас проверила бы только половину того, что ему в итоге выдадут.
	if(session.get_capability(CLIENT_CAPABILITY_RSC) == CLIENT_CAPABILITY_PENDING)
		return FALSE
	var/list/targets = collect_external_delivery_probe_targets()
	if(!length(targets))
		return FALSE
	external_delivery_probe_sent = TRUE
	GLOB.external_delivery_probes_requested++
	tgui_panel.send_external_delivery_probe(targets, session.generation)
	return TRUE

/**
 * Принимает недоверенный отчёт браузера о доступности внешних адресов.
 *
 * Возвращает TRUE, только если отчёт приняли целиком: частично разобранный отчёт
 * не бывает - клиент либо прислал понятную нам форму, либо мусор.
 */
/client/proc/record_external_delivery_probe(list/payload)
	if(!islist(payload))
		return FALSE
	// Кулдаун общий с остальными недоверенными отчётами браузера, ключ свой:
	// иначе клиент, которому нечего терять, заспамил бы asset.log и blackbox.
	var/last_report_at = browser_latency_report_times[CLIENT_DELIVERY_PROBE_REPORT_SOURCE]
	if(!isnull(last_report_at) && world.time - last_report_at < CLIENT_LATENCY_BROWSER_REPORT_COOLDOWN)
		return FALSE
	browser_latency_report_times[CLIENT_DELIVERY_PROBE_REPORT_SOURCE] = world.time

	var/datum/client_resource_session/session = ensure_resource_session()
	// Ответ прошлого жизненного цикла не должен воскрешать capability текущего.
	// Панель переинициализируется вместе с сессией, так что расхождение здесь
	// означает либо гонку перезагрузки чата, либо подделку.
	var/reported_generation = payload["generation"]
	if(!isnum(reported_generation) || reported_generation != session.generation)
		return FALSE

	var/list/results = payload["results"]
	if(!islist(results) || !length(results) || length(results) > CLIENT_DELIVERY_PROBE_MAX_RESULTS)
		return FALSE

	var/list/log_parts = list()
	var/list/latency_details = list()
	var/list/seen_targets = list()
	var/worst_state
	for(var/list/result as anything in results)
		if(!islist(result))
			continue
		var/target_key = result["target"]
		if(!is_external_delivery_probe_target(target_key) || (target_key in seen_targets))
			continue
		var/result_status = result["status"]
		var/state = external_delivery_probe_state(result_status)
		if(isnull(state))
			continue
		seen_targets += target_key
		var/http_status = external_delivery_probe_http_status(result["httpStatus"])
		var/duration_ms = external_delivery_probe_duration_ms(result["durationMs"])
		var/detail = external_delivery_probe_detail(result["detail"])
		var/reason = external_delivery_probe_reason(result_status, http_status, duration_ms, detail)
		worst_state = external_delivery_probe_worst_state(worst_state, state)
		apply_external_delivery_probe_result(target_key, state, reason, session.generation)
		SSblackbox.record_feedback("tally", "resource_delivery_probe", 1, "[target_key]_[state]")
		log_parts += "[target_key] [state] ([reason])"
		latency_details += list(list(
			"target" = target_key,
			"state" = state,
			"status" = "[result_status]",
			"http_status" = http_status,
			"duration_ms" = duration_ms,
			"detail" = detail,
		))

	if(!length(latency_details))
		return FALSE

	// Счётчики раунда считают КЛИЕНТОВ, а не отчёты: второй отчёт того же клиента
	// сдвинул бы долю, ничего не добавив к картине.
	if(!external_delivery_probe_reported)
		external_delivery_probe_reported = TRUE
		switch(worst_state)
			if(CLIENT_CAPABILITY_READY)
				GLOB.external_delivery_probes_ok++
			if(CLIENT_CAPABILITY_DEGRADED)
				GLOB.external_delivery_probes_degraded++
			if(CLIENT_CAPABILITY_FAILED)
				GLOB.external_delivery_probes_failed++
	// Имя без угловых скобок: эта же строка уходит в чат админам, где «<none>»
	// съел бы парсер разметки вместе со всем, что за ним.
	var/reporter = ckey || "неизвестный"
	var/report_line = log_parts.Join("; ")
	if(worst_state == CLIENT_CAPABILITY_FAILED)
		GLOB.external_delivery_probe_failures[reporter] = report_line

	var/log_prefix = (worst_state == CLIENT_CAPABILITY_READY) ? "" : "WARNING: "
	log_asset("[log_prefix]Client delivery probe: [reporter] - [report_line]")
	log_client_latency("external_delivery_probe", src, list(
		"verdict" = worst_state,
		"results" = latency_details,
	))
	return TRUE

/**
 * Кладёт результат по одной цели в capability.
 *
 * Успех у ассетов НЕ поднимаем: READY у CLIENT_CAPABILITY_ASSET_CACHE принадлежит
 * note_asset_cache_ready(), то есть факту отклика окна кеша. Доступный по сети адрес
 * этого не доказывает, и подменять одно другим значило бы объявлять готовым то,
 * чего никто не видел. Провал - другое дело: он сообщает ровно то, чего окно кеша
 * не сообщает никогда.
 */
/client/proc/apply_external_delivery_probe_result(target_key, state, reason, expected_generation)
	var/capability = external_delivery_probe_capability(target_key)
	if(isnull(capability))
		return FALSE
	if(capability == CLIENT_CAPABILITY_ASSET_CACHE && state == CLIENT_CAPABILITY_READY)
		return FALSE
	return ensure_resource_session().set_capability(capability, state, reason, expected_generation)

/// Строки о клиентской пробе для админского отчёта о доставке ресурсов.
/// Отдельным проком по образцу SScdn_probe.get_probe_report_lines().
/proc/build_client_delivery_probe_report_lines()
	if(!GLOB.external_delivery_probes_requested)
		return list("Проба у клиентов: ещё никому не отправлялась (внешних адресов не выдавали либо панель ни у кого не поднялась)")
	var/answered = GLOB.external_delivery_probes_ok + GLOB.external_delivery_probes_degraded + GLOB.external_delivery_probes_failed
	// Молчуны считаются вычитанием намеренно: таймера на клиента здесь нет, потому
	// что он держал бы ссылку на /client и мешал бы его сборке после выхода.
	var/silent = max(GLOB.external_delivery_probes_requested - answered, 0)
	var/list/lines = list("Проба у клиентов: отправлено [GLOB.external_delivery_probes_requested], подтвердили доступность [GLOB.external_delivery_probes_ok], хост ответил отказом у [GLOB.external_delivery_probes_degraded], адрес недоступен у [GLOB.external_delivery_probes_failed], без ответа [silent] (в т.ч. отключившиеся и ещё идущие)")
	if(!GLOB.external_delivery_probes_failed)
		return lines
	var/shown = 0
	for(var/failed_ckey in GLOB.external_delivery_probe_failures)
		if(shown >= CLIENT_DELIVERY_PROBE_REPORT_FAILURES)
			lines += "&nbsp;&nbsp;...и ещё [length(GLOB.external_delivery_probe_failures) - shown], смотрите asset.log"
			break
		shown++
		lines += "&nbsp;&nbsp;<span class='danger'>[failed_ckey]: [GLOB.external_delivery_probe_failures[failed_ckey]]</span>"
	return lines

#undef CLIENT_DELIVERY_PROBE_REPORT_FAILURES
