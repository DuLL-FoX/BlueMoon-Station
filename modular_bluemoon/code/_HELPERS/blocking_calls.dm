/**
 * # Обёртки над блокирующими примитивами
 *
 * Встроенные вызовы BYOND ждут внешние ресурсы двумя принципиально разными способами.
 * savefile, world.Export и блокирующий SQL останавливают весь DreamDaemon. winget и
 * winexists делают сетевой round-trip до скина, но усыпляют только вызывающий proc:
 * мир продолжает тикать. Обе группы полезно измерять, но их нельзя смешивать при
 * определении причины полного внешнего столла.
 *
 * Отличить наше ожидание от честной проблемы хоста изнутри DM можно только одним
 * способом - засечь время вокруг самого примитива. Обёртки ниже делают это и отдают
 * замер в SStick_spikes: дорогие вызовы попадают в кольцо медленной работы (и потом
 * в отчёт о спайке поимённо), а суммарная статистика раз в пять минут уходит в
 * tick_spikes.log. Если сумма по обёрткам сопоставима с суммарным дрифтом спайков -
 * виноваты мы; если нет - виноват хост, и в коде копать нечего.
 *
 * Накладные расходы: два чтения монотонных часов rust-g на вызов. Оборачивать имеет
 * смысл только то, что действительно блокирует - не надо вешать это на горячие проки.
 *
 * ВАЖНО про два разных вида блокировки. winget/winexists НЕ морозят процесс: они
 * УСЫПЛЯЮТ вызывающий прок (см. комментарий в code/datums/browser.dm - "winexists
 * sleeps"), пока ждут ответа скина. Мир при этом продолжает крутиться, world.time
 * идёт, чужой код исполняется. savefile, world.Export и блокирующий SQL наоборот
 * останавливают весь процесс, и world.time за время вызова не сдвигается ни на тик.
 * Отсюда два следствия: (1) миллисекунды этих двух групп нельзя складывать в один
 * итог, (2) момент НАЧАЛА вызова надо отдавать в SStick_spikes отдельно, иначе прок,
 * заснувший в winget во время чужого столла, финиширует ровно в тике спайка и
 * забирает вину на себя (в раунде 9847 так было ошибочно помечено 7 спайков из 97,
 * включая крупнейший на 9782мс).
 */

/// Имя цели для описания замера. Принимает и клиент, и моба.
/proc/blocking_call_target_name(target)
	if(istype(target, /client))
		var/client/target_client = target
		return target_client.ckey || "<клиент без ckey>"
	if(ismob(target))
		var/mob/target_mob = target
		return target_mob.ckey || "[target_mob.type]"
	return "[target]"

/// Из той же цели достаёт клиента для отдельного client_latency timeline.
/proc/blocking_call_target_client(target)
	if(istype(target, /client))
		return target
	if(ismob(target))
		var/mob/target_mob = target
		return target_mob.client
	return null

/**
 * winget с замером. Сигнатура и возвращаемое значение - как у оригинала.
 *
 * winget ждёт ответа скина клиента, усыпляя вызывающий proc на всё время round-trip.
 * Остальной мир продолжает тикать.
 */
/proc/tracked_winget(target, control_id, params)
	if(!SStick_spikes)
		return winget(target, control_id, params)
	var/started_ms = SStick_spikes.now_ms()
	// Прок спит внутри winget, поэтому старт и финиш лежат в РАЗНЫХ тиках. Без старта
	// классификатор спайка не отличит "мы тут и стояли" от "мы просто финишировали в
	// чужом столле" - см. шапку файла.
	var/started_world = world.time
	. = winget(target, control_id, params)
	var/cost_ms = SStick_spikes.now_ms() - started_ms
	// Описание собираем ТОЛЬКО для дорогих вызовов: в статистику по типам идёт каждый,
	// а имя нужно лишь тем, кто попадёт в кольцо. Интерполяция строки на каждом вызове
	// стоила бы дороже самого замера
	var/detail = cost_ms >= SStick_spikes.slow_work_threshold_ms ? "[blocking_call_target_name(target)]: [control_id || "<окно>"].[params]" : null
	SStick_spikes.record_blocking_call("winget", detail, cost_ms, started_world)
	if(detail)
		var/client/target_client = blocking_call_target_client(target)
		target_client?.record_skin_latency("winget", detail, cost_ms, started_world)

/// winexists с замером. Такой же round-trip до скина, как и у winget.
/proc/tracked_winexists(target, control_id)
	if(!SStick_spikes)
		return winexists(target, control_id)
	var/started_ms = SStick_spikes.now_ms()
	var/started_world = world.time
	. = winexists(target, control_id)
	var/cost_ms = SStick_spikes.now_ms() - started_ms
	var/detail = cost_ms >= SStick_spikes.slow_work_threshold_ms ? "[blocking_call_target_name(target)]: [control_id]" : null
	SStick_spikes.record_blocking_call("winexists", detail, cost_ms, started_world)
	if(detail)
		var/client/target_client = blocking_call_target_client(target)
		target_client?.record_skin_latency("winexists", detail, cost_ms, started_world)

/**
 * Ручная пара для блоков, которые обёрткой не накрыть - работа с savefile,
 * world.Export и прочее, где вызовов несколько подряд.
 *
 * Использование:
 *   var/started_ms = blocking_call_start()
 *   ... блокирующая работа ...
 *   blocking_call_finish(started_ms, "savefile", "префы [ckey]")
 *
 * started_world нужен только тем обёрткам, чей блок СПИТ. Синхронный блок (savefile,
 * world.Export, блокирующий SQL) не даёт миру продвинуть world.time, поэтому старт у
 * него равен финишу, и трёхаргументного вызова достаточно.
 */
/proc/blocking_call_start()
	return SStick_spikes?.now_ms()

/proc/blocking_call_finish(started_ms, kind, desc, started_world)
	if(isnull(started_ms) || !SStick_spikes)
		return
	var/cost_ms = SStick_spikes.now_ms() - started_ms
	SStick_spikes.record_blocking_call(kind, desc, cost_ms, started_world)
	if(kind == "world.Export" && cost_ms >= SStick_spikes.slow_work_threshold_ms)
		log_client_latency("blocking_world_export", null, list(
			"latency_ms" = cost_ms,
			"detail" = desc,
		))

/**
 * Измеряемый world.Export для BYOND Topic (`byond://`) между игровыми серверами.
 *
 * HTTP обязан идти через world_safe_http_request(): rust-g не умеет BYOND Topic,
 * поэтому эти оставшиеся вызовы заменить им нельзя. Обёртка намеренно отвергает
 * http(s), чтобы новый веб-запрос не вернул полный стоп мира незаметно.
 */
/proc/tracked_byond_topic_export(url, desc)
	var/lower_url = lowertext("[url]")
	if(findtext(lower_url, "http://") == 1 || findtext(lower_url, "https://") == 1)
		CRASH("HTTP URL passed to tracked_byond_topic_export(); use world_safe_http_request() instead.")
	var/started_ms = blocking_call_start()
	. = world.Export(url)
	blocking_call_finish(started_ms, "world.Export", desc)

/**
 * Отвечает ли скин клиента достаточно быстро, чтобы его вообще имело смысл спрашивать.
 *
 * Судим по последнему пинг-сэмплу: он ездит по тому же каналу, что и ответ на winget,
 * поэтому его свежесть и величина - лучшая доступная оценка стоимости round-trip'а.
 * См. SKIN_RESPONSIVE_* в code/__BLUEMOONCODE/_DEFINES/client_resources.dm.
 *
 * Ни разу не отвечавший клиент считается НЕотвечающим: на входе в игру он как раз
 * занят подкачкой, и именно там winget'ы стоили в раунде 9870 дороже всего.
 *
 * Не-клиента судить не о чем - для него возвращаем TRUE, чтобы вызывающий вёл себя
 * как раньше.
 */
/// Само решение, отделённое от чтения клиента: /client в юнит-тестах не создать.
/proc/skin_responsive_from_sample(last_sample_at, last_rtt_ms, now = world.time)
	if(!last_sample_at)
		return FALSE
	if(now - last_sample_at > SKIN_RESPONSIVE_SAMPLE_MAX_AGE)
		return FALSE
	if(last_rtt_ms > SKIN_RESPONSIVE_MAX_RTT_MS)
		return FALSE
	return TRUE

/proc/client_skin_responsive(client/target)
	if(!istype(target))
		return TRUE
	return skin_responsive_from_sample(target.lastping_at, target.lastping_rtt_raw)

/**
 * winget для косметики: у неотвечающего клиента возвращает null, не сходив никуда.
 *
 * Годится ТОЛЬКО там, где отсутствие ответа не ломает логику, а откладывает украшение -
 * подгонка вьюпорта, dpi, раскладка макросов. Всё, от чего зависит корректность
 * (tgui_window, кеш ассетов, чтение поля ввода), обязано звать tracked_winget напрямую
 * и ждать столько, сколько нужно.
 */
/proc/tracked_winget_deferrable(client/target, control_id, params)
	if(!client_skin_responsive(target))
		SStick_spikes?.record_skipped_blocking_call("winget")
		return null
	return tracked_winget(target, control_id, params)
