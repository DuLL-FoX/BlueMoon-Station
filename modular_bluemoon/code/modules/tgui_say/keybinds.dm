/**
 * Верб открытия окна ввода.
 *
 * Вызывается макросом клавиши, поэтому канал приходит параметром прямо в
 * команде макроса: "tgui-say-open Say".
 */
/client/verb/tgui_say_open_verb(channel as text)
	set name = "tgui-say-open"
	set hidden = TRUE
	set instant = TRUE
	tgui_say_open(channel)

/// Открывает ли этот клиент каналы связи в новом окне.
/client/proc/tgui_say_enabled()
	return prefs?.say_input_mode == SAY_INPUT_MODE_WINDOW && tgui_say?.window

/// Канал окна ввода, соответствующий этой привязке.
/datum/keybinding/client/communication/proc/say_channel()
	return null

/**
 * Верб с параметром для нативного режима.
 *
 * Параметр в объявлении верба важен: получив его, клиент открывает диалог сам
 * и не ждёт сервер, а несколько таких диалогов спокойно живут одновременно.
 * Верб без параметра открывает ввод уже на сервере — там очередь по одному.
 */
/datum/keybinding/client/communication/proc/native_command()
	return null

/datum/keybinding/client/communication/get_clientside_command(client/user)
	var/channel = say_channel()
	if(channel && user.tgui_say_enabled())
		return "tgui-say-open [channel]"
	if(channel && user.prefs?.say_input_mode == SAY_INPUT_MODE_NATIVE)
		var/native = native_command()
		if(native)
			return native
	return clientside

/datum/keybinding/client/communication/say/say_channel()
	return TGUI_SAY_CHANNEL_SAY

/datum/keybinding/client/communication/say/native_command()
	return "Speak"

/datum/keybinding/client/communication/me/say_channel()
	return TGUI_SAY_CHANNEL_ME

/datum/keybinding/client/communication/me/native_command()
	return "Emote"

/datum/keybinding/client/communication/whisper/say_channel()
	return TGUI_SAY_CHANNEL_WHISPER

/datum/keybinding/client/communication/whisper/native_command()
	return "Whisper-Text"

/datum/keybinding/client/communication/ooc/say_channel()
	return TGUI_SAY_CHANNEL_OOC

/datum/keybinding/client/communication/looc/say_channel()
	return TGUI_SAY_CHANNEL_LOOC

/datum/keybinding/client/communication/subtle/say_channel()
	return TGUI_SAY_CHANNEL_SUBTLE

/datum/keybinding/client/communication/subtler/say_channel()
	return TGUI_SAY_CHANNEL_SUBTLER

/datum/keybinding/client/communication/subtler_target/say_channel()
	return TGUI_SAY_CHANNEL_SUBTLER_TARGET
