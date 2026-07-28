/// Способы ввода сообщений, доступные игроку в настройках.
GLOBAL_LIST_INIT(say_input_modes, list(
	SAY_INPUT_MODE_WINDOW,
	SAY_INPUT_MODE_NATIVE,
	SAY_INPUT_MODE_MODAL,
))

/// Окно ввода сообщений, привязанное к клиенту.
/client/var/datum/tgui_say/tgui_say

/**
 * Окно ввода сообщений.
 *
 * Создаётся скрытым при логине и живёт весь раунд. Благодаря этому показ по
 * горячей клавише не требует ни создания окна, ни загрузки бандла: нужно только
 * снять с окна невидимость и отдать ему фокус.
 */
/datum/tgui_say
	/// Клиент, которому принадлежит окно.
	var/client/client
	/// Окно tgui, в котором живёт бандл ввода.
	var/datum/tgui_window/window
	/// Открыто ли окно с точки зрения сервера.
	var/window_open = FALSE
	/// Канал, в котором окно открыто сейчас.
	var/current_channel = TGUI_SAY_CHANNEL_SAY
	/// Предел длины сообщения. Уезжает в окно вместе с props.
	var/max_length = MAX_MESSAGE_LEN

/datum/tgui_say/New(client/client, id)
	. = ..()
	src.client = client
	// Без клиента датум остаётся пустой оболочкой: так его можно создавать
	// в юнит-тестах, где живого клиента взять негде.
	if(!client || !id)
		return
	window = new(client, id)
	window.subscribe(src, PROC_REF(on_message))

/datum/tgui_say/Destroy(force, ...)
	if(window)
		window.unsubscribe(src)
		// logout = TRUE: winset по умирающему клиенту даёт рантайм.
		window.close(can_be_suspended = FALSE, logout = TRUE)
		window = null
	client = null
	return ..()

/**
 * Грузит бандл в скрытое окно.
 *
 * Отложено на несколько секунд: в момент подключения клиент и так занят
 * основным бандлом tgui и панелью чата, а окно ввода в лобби никому не нужно.
 */
/datum/tgui_say/proc/initialize()
	set waitfor = FALSE
	sleep(3 SECONDS)
	if(!client || !window)
		return
	winset(client, TGUI_SAY_WINDOW_ID, "is-visible=0")
	window.initialize(
		fancy = TRUE,
		assets = list(get_asset_datum(/datum/asset/simple/tgui_say)),
	)

/**
 * Окно доложило о готовности.
 *
 * Приводим состояние в закрытое и отдаём стартовые параметры. Сброс важен для
 * переподключений: иначе сервер продолжит считать окно открытым.
 */
/datum/tgui_say/proc/load()
	window_open = FALSE
	current_channel = TGUI_SAY_CHANNEL_SAY
	if(client)
		winset(client, TGUI_SAY_WINDOW_ID, "is-visible=0")
	window?.send_message("props", list(
		"maxLength" = max_length,
		"emotes" = get_emote_keys(),
	))
	return TRUE

/**
 * Ключи эмоций для подсказок в окне.
 *
 * Список берётся у панели эмоций, чтобы не заводить второй источник: она
 * собирает его один раз на весь раунд.
 */
/datum/tgui_say/proc/get_emote_keys()
	var/list/keys = list()
	if(!client?.tgui_panel)
		return keys
	for(var/key in client.tgui_panel.all_emotes)
		keys += key
	return sortTim(keys, GLOBAL_PROC_REF(cmp_text_asc))

/**
 * Окно доложило, что открылось.
 *
 * Сам показ делает фронт: он умеет это без обращения к серверу, и до сервера
 * событие доходит уже постфактум. Здесь остаётся только состояние.
 */
/datum/tgui_say/proc/open(list/payload)
	current_channel = payload?["channel"] || TGUI_SAY_CHANNEL_SAY
	window_open = TRUE
	return TRUE

/// Окно закрылось: игрок отправил сообщение или нажал Escape.
/datum/tgui_say/proc/close()
	window_open = FALSE
	stop_typing()
	return TRUE

/// Единая точка приёма сообщений от окна.
/datum/tgui_say/proc/on_message(type, payload)
	switch(type)
		if("ready")
			return load()
		if("open")
			return open(payload)
		if("close")
			return close()
		if("typing")
			return start_typing()
		if("channel")
			// Смена канала по Tab: индикатор обязан переехать вместе с ней,
			// иначе над игроком висит пузырь речи, пока он пишет в OOC.
			stop_typing()
			current_channel = payload?["channel"] || current_channel
			return TRUE
		if("entry")
			return handle_entry(payload)
	return FALSE

/**
 * Показывает окно ввода в нужном канале.
 *
 * Клавиша движения, отпущенная за время смены фокуса, до сервера не доходит:
 * KeyUp уходит либо в потерявшую фокус карту, либо в ещё не получивший его
 * браузер. Поэтому удержания сбрасываем сами, иначе кукла продолжит бежать,
 * пока игрок печатает.
 */
/client/proc/tgui_say_open(channel)
	if(!tgui_say?.window)
		return FALSE
	ForceAllKeysUp()
	tgui_say.window.send_message("open", list("channel" = channel))
	return TRUE
