/// Панель ввода сообщений. Живёт браузерным элементом внутри панели карты
/// (interface/skin.dmf, window "mapwindow"), а не отдельным окном: так она не
/// уводит фокус операционной системы с главного окна и не теряется за ним.
#define TGUI_SAY_WINDOW_ID "tgui_say"
/// Начало команды открытия, которую клиент выполняет сам. Формат выбран без
/// кавычек и скобок: команда едет в макрос клавиши, а там каждый лишний символ
/// приходится экранировать.
#define TGUI_SAY_OPEN_COMMAND "open:"

// Способ ввода сообщений в каналы связи.
/// Панель ввода: загружена заранее, с историей, каналами и черновиками.
#define SAY_INPUT_MODE_WINDOW "window"
/// Обычный диалог BYOND: открывается самим клиентом, можно держать несколько.
#define SAY_INPUT_MODE_NATIVE "native"
/// Старое окно TGUI: медленнее, но кому-то привычнее.
#define SAY_INPUT_MODE_MODAL "modal"

/// Префикс общего канала рации. Разбор префиксов живёт в get_message_mode(),
/// панель только подставляет его обратно перед отправкой.
#define TGUI_SAY_RADIO_TOKEN ";"

// Где панель стоит на карте.
/// Над панелью действий: HUD игрока нарисован на карте снизу по центру, и
/// панель, прижатая к самому низу, закрывает собой руки и намерения.
#define SAY_INPUT_ANCHOR_HUD "hud"
/// У нижнего края карты, поверх HUD.
#define SAY_INPUT_ANCHOR_BOTTOM "bottom"
/// У верхнего края карты.
#define SAY_INPUT_ANCHOR_TOP "top"

/// Сколько клеток карты панель оставляет под HUD в режиме SAY_INPUT_ANCHOR_HUD.
#define TGUI_SAY_HUD_TILES 2

// Идентификаторы каналов. Строки обязаны совпадать с packages/tgui-say побайтово:
// это единственное, что связывает канал в интерфейсе с веткой маршрутизации в DM.
#define TGUI_SAY_CHANNEL_SAY "Say"
#define TGUI_SAY_CHANNEL_RADIO "Radio"
#define TGUI_SAY_CHANNEL_WHISPER "Whisper"
#define TGUI_SAY_CHANNEL_ME "Me"
#define TGUI_SAY_CHANNEL_SUBTLE "Subtle"
#define TGUI_SAY_CHANNEL_SUBTLER "Subtler"
#define TGUI_SAY_CHANNEL_SUBTLER_TABLE "SubtlerTable"
#define TGUI_SAY_CHANNEL_SUBTLER_TARGET "SubtlerTarget"
#define TGUI_SAY_CHANNEL_NARRATE "Narrate"
#define TGUI_SAY_CHANNEL_NARRATE_SUBTLER "NarrateSubtler"
#define TGUI_SAY_CHANNEL_PRAY "Pray"
#define TGUI_SAY_CHANNEL_LOOC "LOOC"
#define TGUI_SAY_CHANNEL_OOC "OOC"
#define TGUI_SAY_CHANNEL_AOOC "AOOC"
