/**
 * # Этапы выдачи ресурсов клиенту
 *
 * BYOND сообщает об обрыве строкой "Connection failed after handshake (code 0: no/unknown
 * reason)" - то есть не сообщает ничего. Со стороны сервера у нас есть ровно один способ
 * сузить круг: запомнить, докуда дошла выдача ресурсов к моменту обрыва.
 *
 * Смысл шкалы в том, что этапы 0-1 проходят под нагрузкой (клиент тянет .rsc и ассеты),
 * а 2-4 - уже после. Если закрытые соединения массово умирают на 0-1, виноват объём,
 * который мы наливаем в канал на входе; если они доживают до 4 и рвутся позже - дело
 * не в выдаче, и копать надо в сети. Раньше этот вопрос по логам не решался никак.
 */

/// Соединение открыто, ресурсы ещё не запрашивали.
#define CLIENT_RESOURCE_STAGE_CONNECTED 0
/// send_resources() отработал: клиенту назначен источник .rsc и отправлен запрос ассетов.
#define CLIENT_RESOURCE_STAGE_REQUESTED 1
/// Окно кеша ассетов отозвалось - значит канал жив и скин отвечает.
#define CLIENT_RESOURCE_STAGE_ASSETS_ACK 2
/// Поднялся статбраузер.
#define CLIENT_RESOURCE_STAGE_STATBROWSER 3
/// Интерфейс готов полностью (panel_ready от клиента).
#define CLIENT_RESOURCE_STAGE_UI_READY 4

/// Ниже этого этапа соединение считается умершим "на выдаче ресурсов".
#define CLIENT_RESOURCE_STAGE_SURVIVED CLIENT_RESOURCE_STAGE_STATBROWSER

/**
 * Independent client-resource capabilities.
 *
 * The legacy CLIENT_RESOURCE_STAGE_* scale is intentionally retained for round summaries,
 * but it cannot represent a healthy statbrowser next to a failed chat WebView (or vice versa).
 * /datum/client_resource_session owns these states; the old stage fields are compatibility
 * projections used by existing logs and dashboards.
 */
#define CLIENT_CAPABILITY_RSC "rsc"
#define CLIENT_CAPABILITY_ASSET_CACHE "asset_cache"
#define CLIENT_CAPABILITY_STATBROWSER "statbrowser"
#define CLIENT_CAPABILITY_TGUI_PANEL "tgui_panel"
#define CLIENT_CAPABILITY_SKIN "skin"
#define CLIENT_CAPABILITY_BROWSER "browser"

#define CLIENT_CAPABILITY_PENDING "pending"
#define CLIENT_CAPABILITY_REQUESTED "requested"
#define CLIENT_CAPABILITY_READY "ready"
#define CLIENT_CAPABILITY_DEGRADED "degraded"
#define CLIENT_CAPABILITY_FAILED "failed"
#define CLIENT_CAPABILITY_INVALIDATED "invalidated"

/// Как называется источник .rsc в логах, когда внешнего адреса у клиента нет.
#define CLIENT_RSC_SOURCE_LOCAL "DreamDaemon"

/// Сколько ждать доклада статбраузера, прежде чем считать окно непоехавшим.
#define STATBROWSER_LOAD_TIMEOUT (30 SECONDS)

/**
 * # Порог "скин на линии"
 *
 * winget и winexists усыпляют вызывающий прок до ответа скина, и таймаута у них нет.
 * Пока клиент тянет ресурсы, ответа может не быть очень долго: в раунде 9870 худший
 * winget ждал 125 секунд, а в среднем вызов стоил 966мс при медианном пинге 62мс.
 *
 * Отличить занятого клиента от нормального можно по его же пинг-сэмплу: он приезжает
 * через winset+верб, то есть по тому же каналу, что и ответ скина. Свежий и быстрый
 * сэмпл означает, что round-trip дешёвый; протухший или огромный - что спрашивать
 * сейчас нечего, ответ придёт нескоро.
 */
/// Старше этого возраста пинг-сэмпл ничего не говорит о текущем состоянии клиента.
#define SKIN_RESPONSIVE_SAMPLE_MAX_AGE (45 SECONDS)
/// Выше этого RTT клиент занят - почти всегда подкачкой ресурсов или инициализацией
/// WebView/скина. Тысяча миллисекунд была слишком мягким пределом: локальный клиент
/// с RTT 943мс проходил гейт и тут же получал winget, который ждал ещё 2.6 секунды.
/// 250мс оставляет рабочими удалённые подключения, но не пускает косметические
/// запросы в уже доказанную очередь DreamSeeker.
#define SKIN_RESPONSIVE_MAX_RTT_MS 250

/**
 * # Диагностика клиентской задержки
 *
 * Нативный ping ездит не только по сокету: DreamDaemon отдаёт winset-команду,
 * DreamSeeker исполняет её и возвращает hidden verb. Поэтому localhost всё равно
 * способен показать задержку скина, WebView или очереди команд клиента. Эти пороги
 * включают редкое подробное событие, а не меняют видимый игроку ping.
 */
/// С этого RTT пишем подробный native_ping_spike в client_latency.jsonl.
#define CLIENT_LATENCY_RTT_WARN_MS 50
/// Доля RTT, на которой замер уже доказывает остановку игрового времени сервера.
#define CLIENT_LATENCY_SERVER_STALL_WARN_MS 20
/// WebView/TGUI сообщает только достаточно крупные задержки своего event loop/bridge.
#define CLIENT_LATENCY_BROWSER_WARN_MS 100
/// Насколько близким должно быть другое событие, чтобы попасть в причины ping-спайка.
#define CLIENT_LATENCY_CORRELATION_WINDOW (5 SECONDS)
/// Даже стабильно медленный клиент не должен писать JSONL на каждый двухсекундный ping.
#define CLIENT_LATENCY_NATIVE_REPORT_COOLDOWN (10 SECONDS)
/// Серверный предел частоты недоверенных отчётов браузера одного клиента.
#define CLIENT_LATENCY_BROWSER_REPORT_COOLDOWN (5 SECONDS)
