/// Моб, от лица которого уходит речь.
/datum/tgui_say/proc/get_speaker()
	return client?.mob

/// Внутриигровой ли канал. По этому признаку решается и блокировка речи
/// администрацией, и показ индикатора печати.
/datum/tgui_say/proc/is_ic_channel(channel)
	switch(channel)
		if(TGUI_SAY_CHANNEL_LOOC, TGUI_SAY_CHANNEL_OOC, TGUI_SAY_CHANNEL_AOOC)
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
