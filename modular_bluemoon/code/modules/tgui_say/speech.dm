/// Моб, от лица которого уходит речь.
/datum/tgui_say/proc/get_speaker()
	return client?.mob

/// Внутриигровой ли канал. По этому признаку решается и блокировка речи
/// администрацией, и показ индикатора печати.
/datum/tgui_say/proc/is_ic_channel(channel)
	switch(channel)
		if(TGUI_SAY_CHANNEL_LOOC, TGUI_SAY_CHANNEL_OOC, TGUI_SAY_CHANNEL_AOOC, TGUI_SAY_CHANNEL_PRAY)
			return FALSE
	return TRUE

/**
 * Отдаёт текст в тот же путь, которым речь идёт из обычных вербов.
 *
 * Своей логики вывода здесь нет и быть не должно: окно — это только способ
 * набрать текст, все проверки и вся выдача остаются на существующем коде.
 */
/datum/tgui_say/proc/delegate_speech(entry, channel)
	var/mob/speaker = get_speaker()
	if(!speaker)
		return FALSE
	switch(channel)
		if(TGUI_SAY_CHANNEL_SAY)
			speaker.say(entry)
			return TRUE
		if(TGUI_SAY_CHANNEL_RADIO)
			// Префикс общего канала добавляется здесь, а не в окне: разбор
			// префиксов речи остаётся единственным и живёт на сервере.
			speaker.say("[TGUI_SAY_RADIO_TOKEN][entry]")
			return TRUE
		if(TGUI_SAY_CHANNEL_WHISPER)
			speaker.whisper(entry)
			return TRUE
		if(TGUI_SAY_CHANNEL_ME)
			speaker.emote("me", 1, entry, TRUE)
			return TRUE
		// Скрытые эмоции зовём ровно так же, как их вербы: тип эмоции и
		// признак намеренности у них не выставляются, и подменять их нельзя —
		// от них зависят проверки внутри самих эмоций.
		if(TGUI_SAY_CHANNEL_SUBTLE)
			speaker.emote("subtle", message = entry)
			return TRUE
		if(TGUI_SAY_CHANNEL_SUBTLER)
			speaker.emote("subtler", message = entry)
			return TRUE
		if(TGUI_SAY_CHANNEL_SUBTLER_TABLE)
			speaker.emote("subtler_table", message = entry)
			return TRUE
		if(TGUI_SAY_CHANNEL_SUBTLER_TARGET)
			// Цель эмоции спрашивается уже после текста, самой эмоцией.
			speaker.emote("subtler_target", message = list("text" = entry))
			return TRUE
		if(TGUI_SAY_CHANNEL_NARRATE)
			speaker.emote("narrate", message = entry)
			return TRUE
		if(TGUI_SAY_CHANNEL_NARRATE_SUBTLER)
			speaker.emote("narrate_subtler", message = entry)
			return TRUE
		if(TGUI_SAY_CHANNEL_PRAY)
			speaker.pray_message(entry)
			return TRUE
		if(TGUI_SAY_CHANNEL_LOOC)
			if(!client)
				return FALSE
			client.looc_message(entry)
			return TRUE
		if(TGUI_SAY_CHANNEL_OOC)
			if(!client)
				return FALSE
			client.ooc_message(entry)
			return TRUE
		if(TGUI_SAY_CHANNEL_AOOC)
			if(!client)
				return FALSE
			client.aooc_message(entry)
			return TRUE
	return FALSE

/**
 * Разбирает сообщение "entry" от окна.
 *
 * Возвращает TRUE, только если текст действительно ушёл в речь: окно на это
 * не смотрит, но по этому же признаку работают юнит-тесты.
 */
/datum/tgui_say/proc/handle_entry(list/payload)
	if(!islist(payload))
		return FALSE
	var/channel = payload["channel"]
	var/entry = payload["entry"]
	if(!channel || !length(entry))
		return FALSE
	// Предел считается в символах: у кириллицы один символ занимает два байта,
	// и счёт по длине строки урезал бы русский текст вдвое раньше времени.
	if(length_char(entry) > max_length)
		return FALSE
	if(is_ic_channel(channel) && GLOB.say_disabled)
		to_chat(get_speaker(), span_danger("Speech is currently admin-disabled."))
		return FALSE
	return delegate_speech(entry, channel)
