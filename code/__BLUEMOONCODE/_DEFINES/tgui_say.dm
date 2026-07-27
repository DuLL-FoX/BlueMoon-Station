/// Идентификатор окна ввода сообщений в скине (interface/skin.dmf).
#define TGUI_SAY_WINDOW_ID "tgui_say"
/// Браузерный элемент внутри окна ввода. Ему отдаётся фокус при открытии.
#define TGUI_SAY_BROWSER_ID "tgui_say.browser"

/// Префикс общего канала рации. Разбор префиксов живёт в get_message_mode(),
/// окно только подставляет его обратно перед отправкой.
#define TGUI_SAY_RADIO_TOKEN ";"

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
#define TGUI_SAY_CHANNEL_LOOC "LOOC"
#define TGUI_SAY_CHANNEL_OOC "OOC"
#define TGUI_SAY_CHANNEL_AOOC "AOOC"
