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
	return prefs?.tgui_input_verbs && tgui_say?.window

/// Команда макроса для канала, если игрок выбрал новое окно.
/datum/keybinding/client/communication/proc/tgui_say_command(client/user, channel)
	if(!user.tgui_say_enabled())
		return null
	return "tgui-say-open [channel]"

/datum/keybinding/client/communication/say/get_clientside_command(client/user)
	return tgui_say_command(user, TGUI_SAY_CHANNEL_SAY) || clientside

/datum/keybinding/client/communication/me/get_clientside_command(client/user)
	return tgui_say_command(user, TGUI_SAY_CHANNEL_ME) || clientside

/datum/keybinding/client/communication/whisper/get_clientside_command(client/user)
	return tgui_say_command(user, TGUI_SAY_CHANNEL_WHISPER) || clientside

/datum/keybinding/client/communication/ooc/get_clientside_command(client/user)
	return tgui_say_command(user, TGUI_SAY_CHANNEL_OOC) || clientside

/datum/keybinding/client/communication/looc/get_clientside_command(client/user)
	return tgui_say_command(user, TGUI_SAY_CHANNEL_LOOC) || clientside

/datum/keybinding/client/communication/subtle/get_clientside_command(client/user)
	return tgui_say_command(user, TGUI_SAY_CHANNEL_SUBTLE) || clientside

/datum/keybinding/client/communication/subtler/get_clientside_command(client/user)
	return tgui_say_command(user, TGUI_SAY_CHANNEL_SUBTLER) || clientside

/datum/keybinding/client/communication/subtler_target/get_clientside_command(client/user)
	return tgui_say_command(user, TGUI_SAY_CHANNEL_SUBTLER_TARGET) || clientside
