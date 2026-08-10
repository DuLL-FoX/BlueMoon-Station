/**
 * # SScdn_probe - активная проба внешней раздачи
 *
 * Ветка с версионным .rsc, webroot-транспортом ассетов и HTTP-медиа лобби убрала из
 * канала клиента десятки мегабайт, но взамен завела зависимость от чужого хоста. Про
 * его падение сервер узнавал последним: клиенты молча уходят на локальные пути, лобби
 * просто открывается медленнее, а .rsc не приезжает вовсе - и всё это выглядит как
 * "у меня лагает", пока кто-нибудь не напишет в Discord.
 *
 * Пассивных счётчиков для этого мало: они срабатывают ТОЛЬКО когда игрок уже споткнулся.
 * Раздача может лечь в пустом лобби и ждать первого входа, чтобы сообщить о себе жалобой.
 * Поэтому здесь сервер сам ходит по трём адресам и решает за игроков:
 *
 *  - версионный архив .rsc: только сигнал админам с подсказкой про верб. Автоматически
 *    отключать выдачу нельзя - клиент уже в игре, а решение "раздаём медленно, но всем"
 *    стоит целого раунда и принимает его человек;
 *  - webroot браузерных ассетов: сигнал плюс перевод транспорта на раздачу через
 *    DreamDaemon (fallback_to_simple_transport). Публикацию ассетов увёз деплой, так
 *    что сам транспорт свой отказ больше не видит - кроме пробы, сорвать его некому.
 *    Автоматика уместна по той же логике, что у лобби: цена ошибки - ассеты грузятся
 *    медленнее, а верб «Toggle CDN» возвращает CDN одним действием;
 *  - медиа лобби: сигнал плюс глушение внешних адресов. Здесь автоматика уместна -
 *    цена ошибки ровно одна лишняя картинка через DreamDaemon, а без глушения каждый
 *    входящий игрок платит таймаутом браузера и обратным href на сервер.
 *
 * Запросы уходят HEAD'ом через rustg: world.Export() исполнил бы их на главном потоке
 * и держал бы весь мир до ответа удалённой стороны, а здесь вызывающий спит на
 * поллинге джобы, и мир тикает.
 */

/// Сколько проб подряд по одной цели должны провалиться, прежде чем ей верить.
/// Одиночный таймаут - это сеть, три подряд - это упавшая раздача.
#define CDN_PROBE_FAILURE_THRESHOLD 3
/// Сколько ждать ответа на один запрос.
#define CDN_PROBE_REQUEST_TIMEOUT (20 SECONDS)
/// Дольше этого пачка запросов идти не может даже в худшем случае. Нужен, чтобы
/// оборвавшийся посреди пачки проход не запирал подсистему до конца раунда.
#define CDN_PROBE_PASS_DEADLINE (3 MINUTES)

/// Ключи целей: они же ключи счётчиков неудач.
#define CDN_PROBE_TARGET_RSC "rsc"
#define CDN_PROBE_TARGET_ASSETS "assets"
#define CDN_PROBE_TARGET_LOBBY "lobby"

/**
 * Вердикты пробы.
 *
 * "Не проверено" - самостоятельное состояние, а НЕ разновидность успеха. Хост,
 * отвечающий отказом на сам метод, не сказал про адрес ничего: файла может не быть.
 * Считать такой ответ здоровым значит снимать глушение, поставленное реально
 * пропавшим файлом, - тот же цикл мигания медиа, только зашедший с другой стороны.
 * Считать его отказом тоже нельзя: хост жив, кричать админам не о чем.
 */
#define CDN_PROBE_VERDICT_HEALTHY "healthy"
#define CDN_PROBE_VERDICT_INDETERMINATE "indeterminate"
#define CDN_PROBE_VERDICT_FAILED "failed"

/// Индексы в паре, которую отдаёт classify_probe_response().
#define CDN_PROBE_VERDICT 1
#define CDN_PROBE_VERDICT_REASON 2

/// Хост отказывается отвечать на САМ МЕТОД, а не выносит вердикт о файле: nginx с
/// limit_except и часть прокси HEAD не отдают.
#define CDN_PROBE_STATUS_METHOD_NOT_ALLOWED 405
#define CDN_PROBE_STATUS_NOT_IMPLEMENTED 501
/// Границы "здорового" диапазона: 2xx - файл на месте, 3xx - переезд, тоже ответ.
#define CDN_PROBE_STATUS_HEALTHY_MIN 200
#define CDN_PROBE_STATUS_HEALTHY_MAX 400

SUBSYSTEM_DEF(cdn_probe)
	name = "CDN Probe"
	flags = SS_BACKGROUND
	wait = 5 MINUTES
	runlevels = RUNLEVEL_LOBBY | RUNLEVELS_DEFAULT

	/// Ключ цели -> сколько проб подряд не удались.
	var/list/consecutive_failures = list()
	/// Ключ цели -> админам про её отказ уже сказали.
	var/list/alerted = list()
	/// Ключ цели -> адрес, по которому ходили в последний раз. Для отчёта.
	var/list/last_probed_url = list()
	/// Ключ цели -> текст последней неудачи.
	var/list/last_failure_reason = list()
	/// Ключ цели -> вердикт последней пробы, см. CDN_PROBE_VERDICT_*. Нужен отчёту:
	/// цель, которую нечем проверить, не то же самое, что цель, которая отвечает.
	var/list/last_verdict = list()
	/// TRUE, пока пачка запросов в полёте.
	var/probing = FALSE
	/// world.time начала текущей пачки.
	var/probe_started_at = 0
	/// Про отказ хоста отвечать на HEAD говорим один раз за раунд.
	var/head_refusal_logged = FALSE

/datum/controller/subsystem/cdn_probe/Initialize(start_timeofday)
	apply_config()
	return ..()

/datum/controller/subsystem/cdn_probe/OnConfigLoad()
	apply_config()

/// Интервал живёт в конфиге в секундах: децисекунды в конфиге читать невозможно.
/// Ноль означает "не проверять" - у сервера может не быть выхода наружу вовсе.
/datum/controller/subsystem/cdn_probe/proc/apply_config()
#ifdef UNIT_TESTS
	// Тестовому миру некого защищать, а исходящий запрос в CI - это ожидание там,
	// где сети может не быть вовсе. Конфиг при этом не трогаем: прод его читает.
	can_fire = FALSE
	return
#endif
	var/interval_seconds = CONFIG_GET(number/cdn_probe_interval)
	if(interval_seconds <= 0)
		can_fire = FALSE
		return
	can_fire = TRUE
	wait = interval_seconds SECONDS

/datum/controller/subsystem/cdn_probe/Recover()
	consecutive_failures = SScdn_probe.consecutive_failures
	alerted             = SScdn_probe.alerted
	last_probed_url     = SScdn_probe.last_probed_url
	last_failure_reason = SScdn_probe.last_failure_reason
	last_verdict        = SScdn_probe.last_verdict
	head_refusal_logged = SScdn_probe.head_refusal_logged
	// Пачка старого экземпляра всё ещё спит на поллинге и снимет флаг с НЕГО, не с нас.
	// Переносим флаг вместе с меткой времени: пока не истёк CDN_PROBE_PASS_DEADLINE,
	// новый экземпляр не запустит второй проход поверх первого, а после - запустит.
	probing             = SScdn_probe.probing
	probe_started_at    = SScdn_probe.probe_started_at
	// can_fire и wait живут на экземпляре, а новый их не читал ни разу: без этого
	// выключенная CDN_PROBE_INTERVAL 0 проба воскресала бы с дефолтными пятью минутами,
	// а под UNIT_TESTS - вообще начинала бы ходить наружу.
	apply_config()

/datum/controller/subsystem/cdn_probe/fire(resumed = FALSE)
	if(probing && world.time < probe_started_at + CDN_PROBE_PASS_DEADLINE)
		return
	var/list/probe_targets = collect_probe_targets()
	// Ни одной внешней раздачи в этой сборке - ходить наружу не за чем. Так выглядит
	// любая локальная сборка: деплой ничего не зашивал, webroot не настроен, манифеста
	// лобби нет. Пробу в этом случае даже не будим.
	if(!length(probe_targets))
		return
	probing = TRUE
	probe_started_at = world.time
	// Запросы спят на поллинге джобы rustg, поэтому уводим их из тика МК целиком:
	// fire() вернётся на первом же сне внутри прохода.
	INVOKE_ASYNC(src, PROC_REF(run_probe_pass), probe_targets)

/// Ключ цели -> адрес или список адресов. Пропавшим целям обнуляем счётчик: выключенная цель не должна
/// копить неудачи и кричать о них, когда её вернут.
/datum/controller/subsystem/cdn_probe/proc/collect_probe_targets()
	var/list/probe_targets = list()
	var/list/rsc_urls = get_rsc_probe_urls()
	if(length(rsc_urls))
		probe_targets[CDN_PROBE_TARGET_RSC] = rsc_urls
	var/asset_url = get_asset_probe_url()
	if(asset_url)
		probe_targets[CDN_PROBE_TARGET_ASSETS] = asset_url
	var/lobby_url = get_lobby_probe_url()
	if(lobby_url)
		probe_targets[CDN_PROBE_TARGET_LOBBY] = lobby_url
	for(var/target_key in list(CDN_PROBE_TARGET_RSC, CDN_PROBE_TARGET_ASSETS, CDN_PROBE_TARGET_LOBBY))
		if(probe_targets[target_key])
			continue
		consecutive_failures[target_key] = 0
		last_probed_url[target_key] = null //иначе отчёт покажет адрес, которого уже нет
		last_verdict[target_key] = null
		// Снятый алерт обязателен: иначе вернувшаяся цель, о которой уже кричали,
		// второй раз не докричится - счётчик обнулён, а флаг «уже сказали» остался.
		alerted[target_key] = FALSE
	return probe_targets

/datum/controller/subsystem/cdn_probe/proc/run_probe_pass(list/probe_targets)
	for(var/target_key in probe_targets)
		if(target_key == CDN_PROBE_TARGET_RSC)
			probe_rsc_targets(probe_targets[target_key])
			continue
		probe_target(target_key, probe_targets[target_key])
	probing = FALSE

/// Проверяем каждый адрес из той же ротации, которую получает клиент. Один сломанный
/// адрес делает всю ротацию сломанной: часть подключений иначе неизбежно попадёт на него.
/datum/controller/subsystem/cdn_probe/proc/probe_rsc_targets(list/urls)
	var/list/verdicts_by_url = list()
	for(var/url in urls)
		verdicts_by_url[url] = classify_probe_response(head_request(url))
	var/list/verdict = summarize_cdn_probe_verdicts(verdicts_by_url)
	var/urls_text = urls.Join(", ")
	last_probed_url[CDN_PROBE_TARGET_RSC] = urls_text
	last_verdict[CDN_PROBE_TARGET_RSC] = verdict[CDN_PROBE_VERDICT]
	switch(verdict[CDN_PROBE_VERDICT])
		if(CDN_PROBE_VERDICT_FAILED)
			record_probe_failure(CDN_PROBE_TARGET_RSC, urls_text, verdict[CDN_PROBE_VERDICT_REASON])
		if(CDN_PROBE_VERDICT_HEALTHY)
			record_probe_success(CDN_PROBE_TARGET_RSC, urls_text)
		if(CDN_PROBE_VERDICT_INDETERMINATE)
			note_head_refusal(CDN_PROBE_TARGET_RSC, urls_text, verdict[CDN_PROBE_VERDICT_REASON])

/// Один запрос и действие по его вердикту.
/datum/controller/subsystem/cdn_probe/proc/probe_target(target_key, url)
	last_probed_url[target_key] = url
	var/list/verdict = classify_probe_response(head_request(url))
	last_verdict[target_key] = verdict[CDN_PROBE_VERDICT]
	switch(verdict[CDN_PROBE_VERDICT])
		if(CDN_PROBE_VERDICT_FAILED)
			record_probe_failure(target_key, url, verdict[CDN_PROBE_VERDICT_REASON])
		if(CDN_PROBE_VERDICT_HEALTHY)
			record_probe_success(target_key, url)
		if(CDN_PROBE_VERDICT_INDETERMINATE)
			// Состояние цели не трогаем ВООБЩЕ: ни счётчик неудач, ни глушение. Про
			// сам адрес мы не узнали ничего, и любое движение здесь было бы выдумкой.
			note_head_refusal(target_key, url, verdict[CDN_PROBE_VERDICT_REASON])

/**
 * HEAD с таймаутом, не задевающий тик.
 *
 * Использует общий ограниченный по времени rust-g путь, но метод HEAD: качать
 * многомегабайтный архив .rsc каждые пять минут ради проверки живости хоста дороже
 * самой проблемы. world.Export() тем более не годится - он исполняет запрос на
 * главном потоке и держит весь мир до ответа удалённой стороны.
 *
 * Возвращает /datum/http_response или null, если ответа не дождались.
 */
/datum/controller/subsystem/cdn_probe/proc/head_request(url)
	return world_safe_http_request(RUSTG_HTTP_METHOD_HEAD, url, timeout = CDN_PROBE_REQUEST_TIMEOUT)

/**
 * Чистый разбор ответа: list(вердикт, человекочитаемая причина). Побочных действий нет.
 *
 * Здоровы 2xx/3xx - файл на месте. 403 и 404 остаются отказами: адреса у нас ведут на
 * конкретные файлы, и «файла нет» - ровно тот случай, ради которого проба заводилась
 * (ср. verify_public_url() в tools/rsc_deploy/rsc_deploy.py, где 4xx на конкретном файле
 * это сразу вердикт; «любой ответ здоров» там только у probe_public_base_url(), а он
 * проверяет каталог, где листинг выключен штатно).
 *
 * 405 и 501 - ни то, ни другое. Хост отказал МЕТОДУ и про файл не сказал ничего:
 * ни кричать о падении, ни объявлять адрес живым по такому ответу нельзя.
 */
/datum/controller/subsystem/cdn_probe/proc/classify_probe_response(datum/http_response/response)
	if(isnull(response))
		return list(CDN_PROBE_VERDICT_FAILED, "ответа нет за [DisplayTimeText(CDN_PROBE_REQUEST_TIMEOUT)]")
	if(response.errored)
		return list(CDN_PROBE_VERDICT_FAILED, "ошибка запроса: [response.error]")
	if(response.status_code >= CDN_PROBE_STATUS_HEALTHY_MIN && response.status_code < CDN_PROBE_STATUS_HEALTHY_MAX)
		return list(CDN_PROBE_VERDICT_HEALTHY, "ответ [response.status_code]")
	if(response.status_code == CDN_PROBE_STATUS_METHOD_NOT_ALLOWED || response.status_code == CDN_PROBE_STATUS_NOT_IMPLEMENTED)
		return list(CDN_PROBE_VERDICT_INDETERMINATE, "ответ [response.status_code]: HEAD не принимается")
	return list(CDN_PROBE_VERDICT_FAILED, "ответ [response.status_code]")

/// Чистая сводка нескольких RSC-зеркал. Отказ хотя бы одного опаснее остальных
/// результатов; без отказов неопределённый HEAD не позволяет объявить набор здоровым.
/proc/summarize_cdn_probe_verdicts(list/verdicts_by_url)
	var/list/failures = list()
	var/list/indeterminate = list()
	for(var/url in verdicts_by_url)
		var/list/verdict = verdicts_by_url[url]
		switch(verdict[CDN_PROBE_VERDICT])
			if(CDN_PROBE_VERDICT_FAILED)
				failures += "[url]: [verdict[CDN_PROBE_VERDICT_REASON]]"
			if(CDN_PROBE_VERDICT_INDETERMINATE)
				indeterminate += "[url]: [verdict[CDN_PROBE_VERDICT_REASON]]"
	if(length(failures))
		return list(CDN_PROBE_VERDICT_FAILED, failures.Join("; "))
	if(length(indeterminate))
		return list(CDN_PROBE_VERDICT_INDETERMINATE, indeterminate.Join("; "))
	return list(CDN_PROBE_VERDICT_HEALTHY, "все адреса ответили ([length(verdicts_by_url)] шт.)")

/// Раздача не принимает HEAD, значит проверять её нечем: проба по этому адресу не
/// решает ничего и состояние цели не двигает. Молчать нельзя - иначе «в отчёте не
/// красное» будет читаться как «проверено и живо».
/datum/controller/subsystem/cdn_probe/proc/note_head_refusal(target_key, url, reason)
	if(head_refusal_logged)
		return
	head_refusal_logged = TRUE
	log_asset("CDN probe: [target_key] проверить нечем - [url] отвечает «[reason]». Проба по этой цели ничего не подтверждает и ничего не опровергает.")

/datum/controller/subsystem/cdn_probe/proc/record_probe_failure(target_key, url, failure_reason)
	var/failures = (consecutive_failures[target_key] || 0) + 1
	consecutive_failures[target_key] = failures
	last_failure_reason[target_key] = failure_reason
	if(failures < CDN_PROBE_FAILURE_THRESHOLD || alerted[target_key])
		return
	alerted[target_key] = TRUE
	log_asset("WARNING: CDN probe: [target_key] не отвечает, провалов подряд: [failures] ([url]): [failure_reason]")
	switch(target_key)
		if(CDN_PROBE_TARGET_RSC)
			// Автоматически не выключаем: раздача через DreamDaemon стоит канала на
			// каждом входе, и цену этого решения должен назначать человек.
			message_admins("Один или несколько адресов раздачи .rsc не отвечают, провалов подряд: [failures] ([url]): [failure_reason]. \
				Входящие клиенты не получат архив ресурсов. Верб «Toggle External RSC» переключит их на выдачу с сервера.")
		if(CDN_PROBE_TARGET_ASSETS)
			// Фолбэк сам инвалидирует выданные URL и перезаливает открытые окна;
			// после него транспорт перестаёт быть webroot, цель выпадает из
			// списка проб, и второй раз этот сигнал не сработает.
			var/datum/asset_transport/webroot/webroot_transport = SSassets.transport
			if(istype(webroot_transport))
				webroot_transport.fallback_to_simple_transport("проба не достучалась до [url]: [failure_reason]")
			message_admins("Раздача браузерных ассетов не отвечает, провалов подряд: [failures] ([url]): [failure_reason]. \
				Верб «Toggle CDN» вернёт CDN, когда раздача оживёт.")
		if(CDN_PROBE_TARGET_LOBBY)
			// Адрес отдаём явно: снимать глушение потом можно только по нему, иначе
			// живая картинка «починит» пропавший трек и всё пойдёт по кругу.
			if(SStitle_bm)
				SStitle_bm.suppress_external_media("проба не достучалась до [url]: [failure_reason]", announce = FALSE, probe_url = url)
			message_admins("Раздача медиа лобби не отвечает, провалов подряд: [failures] ([url]): [failure_reason]. \
				Внешние адреса больше не выдаём, картинки и музыка идут через DreamDaemon.")

/datum/controller/subsystem/cdn_probe/proc/record_probe_success(target_key, url)
	last_failure_reason[target_key] = null
	consecutive_failures[target_key] = 0
	// Глушение лобби-медиа мог поставить и порог фолбэков по игрокам, а не проба.
	// Снимаем его по факту живого адреса, а не по своему же счётчику: иначе
	// заглушённая жалобами раздача так и осталась бы заглушённой до конца раунда.
	// restore_external_media сама решает, не исчерпан ли лимит автоснятий, и сама
	// пишет в лог и говорит админам.
	if(target_key == CDN_PROBE_TARGET_LOBBY && SStitle_bm?.restore_external_media("проба достучалась до [url]"))
		alerted[target_key] = FALSE
		return
	if(!alerted[target_key])
		return
	alerted[target_key] = FALSE
	// Раздача ожила, а медиа всё равно на DreamDaemon - значит снятие отклонил лимит.
	// Молча оставлять админа в этом состоянии нельзя: по одному "снова отвечает" он
	// решит, что всё вернулось само.
	var/still_suppressed = (target_key == CDN_PROBE_TARGET_LOBBY) && SStitle_bm?.external_media_suppressed
	log_asset("CDN probe: [target_key] снова отвечает ([url])")
	message_admins("Раздача ([target_key]) снова отвечает: [url][still_suppressed ? ". Лимит автоснятий за раунд исчерпан - медиа лобби остаётся на DreamDaemon до конца раунда." : ""]")

/**
 * Все адреса версионного архива - тот же набор, по которому ротируются клиенты.
 *
 * Только зашитый деплоем, конфигурационный EXTERNAL_RSC_URLS намеренно не берём.
 * В config/entries/resources.txt он лежит РАСКОММЕНТИРОВАННЫМ и указывает на боевую
 * раздачу, то есть это значение никто не выбирал - оно приехало с репозиторием. Пробуя
 * его, всякая локальная сборка ходила бы наружу и кричала своему же владельцу (а он
 * там и админ), что раздача лежит, хотя у него просто нет доступа в сеть. Зашитый
 * адрес - доказательство настоящего деплоя; боевые сборки идут через TGS и rsc_deploy,
 * так что мониторинг там на месте.
 *
 * Выключенная вербом выдача пробы не требует: адрес всё равно никому не уедет.
 */
/datum/controller/subsystem/cdn_probe/proc/get_rsc_probe_urls()
	if(!GLOB.external_rsc_delivery_enabled)
		return list()
	var/static/list/deployment_rsc_urls = DEPLOYMENT_RSC_URLS
	return length(deployment_rsc_urls) ? deployment_rsc_urls.Copy() : list()

/// Адрес статбраузера: из всех опубликованных ассетов именно он ломает раунд громче
/// всех - без него у игрока нет статпанели и не выставляется statbrowser_ready.
/datum/controller/subsystem/cdn_probe/proc/get_asset_probe_url()
	if(!istype(SSassets?.transport, /datum/asset_transport/webroot))
		return null
	var/datum/asset/simple/namespaced/bluemoon_statbrowser/statbrowser_asset = get_asset_datum(/datum/asset/simple/namespaced/bluemoon_statbrowser)
	var/datum/asset_cache_item/statbrowser_item = statbrowser_asset?.assets?["statbrowser.html"]
	if(!statbrowser_item)
		return null
	return SSassets.transport.get_asset_url("statbrowser.html", statbrowser_item)

/datum/controller/subsystem/cdn_probe/proc/get_lobby_probe_url()
	return SStitle_bm?.get_media_probe_url()

/// Почему у цели нет адреса, по которому ходили. Для .rsc «адреса нет» и «адреса есть,
/// но выдача выключена» - разные состояния: во втором случае архив никуда не делся и
/// вернётся тем же вербом, а отчёт до этого уверял админа, что сборка вовсе без
/// версионного архива.
/datum/controller/subsystem/cdn_probe/proc/describe_unprobed_target(target_key)
	if(target_key != CDN_PROBE_TARGET_RSC)
		return "не проверяется (адреса нет)"
	var/static/list/report_deployment_rsc_urls = DEPLOYMENT_RSC_URLS
	if(!length(report_deployment_rsc_urls))
		return "не проверяется (адреса нет)"
	if(!GLOB.external_rsc_delivery_enabled)
		return "не проверяется: внешняя выдача выключена, адреса ([length(report_deployment_rsc_urls)] шт.) зашиты в сборку и вернутся вербом «Toggle External RSC»"
	return "адреса есть ([length(report_deployment_rsc_urls)] шт.), проба по ним ещё не ходила"

/// Строки о состоянии проб для админского отчёта о доставке ресурсов.
/datum/controller/subsystem/cdn_probe/proc/get_probe_report_lines()
	if(!can_fire)
		return list("Активная проба выключена конфигом (CDN_PROBE_INTERVAL 0)")
	var/list/lines = list("Активная проба: раз в [DisplayTimeText(wait)]")
	if(head_refusal_logged)
		lines += "&nbsp;&nbsp;раздача не принимает HEAD: такие цели проба не подтверждает и не опровергает, смотрите asset.log"
	for(var/target_key in list(CDN_PROBE_TARGET_RSC, CDN_PROBE_TARGET_ASSETS, CDN_PROBE_TARGET_LOBBY))
		var/url = last_probed_url[target_key]
		if(!url)
			lines += "&nbsp;&nbsp;[target_key]: [describe_unprobed_target(target_key)]"
			continue
		if(last_verdict[target_key] == CDN_PROBE_VERDICT_INDETERMINATE)
			lines += "&nbsp;&nbsp;[target_key]: проверить нечем, HEAD не принимается - [url]"
			continue
		var/failures = consecutive_failures[target_key] || 0
		if(!failures)
			lines += "&nbsp;&nbsp;[target_key]: отвечает ([url])"
			continue
		lines += "&nbsp;&nbsp;<span class='danger'>[target_key]: неудач подряд [failures] ([last_failure_reason[target_key] || "причина неизвестна"]) - [url]</span>"
	return lines

#undef CDN_PROBE_FAILURE_THRESHOLD
#undef CDN_PROBE_REQUEST_TIMEOUT
#undef CDN_PROBE_PASS_DEADLINE
#undef CDN_PROBE_TARGET_RSC
#undef CDN_PROBE_TARGET_ASSETS
#undef CDN_PROBE_TARGET_LOBBY
#undef CDN_PROBE_VERDICT_HEALTHY
#undef CDN_PROBE_VERDICT_INDETERMINATE
#undef CDN_PROBE_VERDICT_FAILED
#undef CDN_PROBE_VERDICT
#undef CDN_PROBE_VERDICT_REASON
#undef CDN_PROBE_STATUS_METHOD_NOT_ALLOWED
#undef CDN_PROBE_STATUS_NOT_IMPLEMENTED
#undef CDN_PROBE_STATUS_HEALTHY_MIN
#undef CDN_PROBE_STATUS_HEALTHY_MAX
