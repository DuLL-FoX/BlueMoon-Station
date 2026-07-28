/// Каналы, для которых показывается пузырь эмоута, а не речи.
/datum/tgui_say/proc/is_emote_channel(channel)
	switch(channel)
		if(TGUI_SAY_CHANNEL_ME, TGUI_SAY_CHANNEL_SUBTLE, TGUI_SAY_CHANNEL_SUBTLER, TGUI_SAY_CHANNEL_SUBTLER_TABLE, TGUI_SAY_CHANNEL_SUBTLER_TARGET, TGUI_SAY_CHANNEL_NARRATE, TGUI_SAY_CHANNEL_NARRATE_SUBTLER)
			return TRUE
	return FALSE

/**
 * Игрок набирает текст.
 *
 * Индикатор зажигается именно здесь, а не при открытии окна: иначе пузырь
 * висит над теми, кто открыл окно и передумал. Повторный сигнал продлевает
 * уже показанный индикатор — окно шлёт его, пока человек печатает.
 */
/datum/tgui_say/proc/start_typing()
	if(!is_ic_channel(current_channel))
		return FALSE
	var/mob/speaker = get_speaker()
	if(!speaker)
		return FALSE
	if(speaker.typing_indicator_current)
		return speaker.refresh_typing_indicator()
	if(is_emote_channel(current_channel))
		speaker.display_typing_indicator(isMe = TRUE)
	else
		speaker.display_typing_indicator(isSay = TRUE)
	return TRUE

/// Окно закрылось или сообщение ушло — гасим индикатор немедленно.
/datum/tgui_say/proc/stop_typing()
	var/mob/speaker = get_speaker()
	if(!speaker)
		return FALSE
	speaker.clear_typing_indicator()
	return TRUE
