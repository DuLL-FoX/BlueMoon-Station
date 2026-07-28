/// Способы ввода сообщений, доступные игроку в настройках.
GLOBAL_LIST_INIT(say_input_modes, list(
	SAY_INPUT_MODE_WINDOW,
	SAY_INPUT_MODE_NATIVE,
	SAY_INPUT_MODE_MODAL,
))

/// Панель ввода сообщений, привязанная к клиенту.
/client/var/datum/tgui_say/tgui_say

/**
 * Панель ввода сообщений.
 *
 * Создаётся скрытой при логине и живёт весь раунд. Благодаря этому показ по
 * горячей клавише не требует ни создания окна, ни загрузки бандла: клиент сам
 * снимает с панели невидимость и отдаёт ей фокус, сервер узнаёт об этом уже
 * постфактум.
 */
/datum/tgui_say
	/// Клиент, которому принадлежит панель.
	var/client/client
	/// Окно tgui, в котором живёт бандл ввода.
	var/datum/tgui_window/window
	/// Догрузился ли бандл. До этого клавиши обязаны вести в старый ввод:
	/// команда открытия работает только по живой панели.
	var/window_ready = FALSE
	/// Открыта ли панель с точки зрения сервера.
	var/window_open = FALSE
	/// Канал, в котором панель работает сейчас. Каналов на экране может быть
	/// несколько, но индикатор печати идёт по активной строке.
	var/current_channel = TGUI_SAY_CHANNEL_SAY
	/// Предел длины сообщения. Уезжает в панель вместе с props.
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
 * Грузит бандл в скрытую панель.
 *
 * Отложено на несколько секунд: в момент подключения клиент и так занят
 * основным бандлом tgui и панелью чата, а ввод в лобби никому не нужен.
 */
/datum/tgui_say/proc/initialize()
	set waitfor = FALSE
	sleep(3 SECONDS)
	if(!client || !window)
		return
	winset(client, TGUI_SAY_WINDOW_ID, "is-visible=0")
	// Панель — браузерный элемент внутри карты, а не отдельное окно: параметры
	// рамки ему не нужны, как и панели чата.
	window.initialize(assets = list(get_asset_datum(/datum/asset/simple/tgui_say)))

/**
 * Панель доложила о готовности.
 *
 * Приводим состояние в закрытое и отдаём стартовые параметры. Сброс важен для
 * переподключений: иначе сервер продолжит считать панель открытой.
 */
/datum/tgui_say/proc/load()
	window_open = FALSE
	window_ready = TRUE
	current_channel = TGUI_SAY_CHANNEL_SAY
	if(client)
		winset(client, TGUI_SAY_WINDOW_ID, "is-visible=0")
		// Только теперь клавиши можно переводить на прямое открытие: до
		// загрузки бандла команда ушла бы в пустоту, и игрок остался бы без
		// речи. Пересборка макросов сама выберет нужные команды.
		if(client.prefs?.say_input_mode == SAY_INPUT_MODE_WINDOW)
			client.ensure_keys_set()
	window?.send_message("props", list(
		"maxLength" = max_length,
		"emotes" = get_emote_keys(),
	))
	return TRUE

/**
 * Ключи эмоций для подсказок в панели.
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
 * Панель доложила, что открылась.
 *
 * Сам показ делает фронт: он умеет это без обращения к серверу, и до сервера
 * событие доходит уже постфактум. Здесь остаётся состояние и сброс удержанных
 * клавиш: KeyUp, отпущенный за время смены фокуса, до сервера не доходит, и
 * кукла продолжила бы бежать, пока игрок печатает.
 */
/datum/tgui_say/proc/open(list/payload)
	current_channel = payload?["channel"] || TGUI_SAY_CHANNEL_SAY
	window_open = TRUE
	client?.ForceAllKeysUp()
	return TRUE

/// Панель закрылась: игрок отправил сообщение или свернул её.
/datum/tgui_say/proc/close()
	window_open = FALSE
	stop_typing()
	return TRUE

/// Прячет панель с сервера. Нужно там, где игрок сам её закрыть уже не может:
/// смена настройки ввода, потеря права говорить, конец раунда.
/datum/tgui_say/proc/hide()
	if(!window_ready)
		return FALSE
	window?.send_message("close")
	return TRUE

/// Единая точка приёма сообщений от панели.
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
			// Активная строка сменилась: индикатор обязан переехать вместе с
			// ней, иначе над игроком висит пузырь речи, пока он пишет в OOC.
			stop_typing()
			current_channel = payload?["channel"] || current_channel
			return TRUE
		if("entry")
			return handle_entry(payload)
	return FALSE

/// Готова ли панель принимать открытие. До загрузки бандла клавиши обязаны
/// вести в старый ввод, иначе игрок молча остаётся без речи.
/client/proc/tgui_say_ready()
	return prefs?.say_input_mode == SAY_INPUT_MODE_WINDOW && tgui_say?.window_ready

/**
 * Команда открытия, которую клиент выполняет сам.
 *
 * Кавычки обязательны: параметры winset разделяются в том числе пробелом, и
 * команда без них обрезается по первому же пробелу — клавиша перестаёт
 * открывать панель. Тем же способом кавычатся штатные макросы движения
 * (SSinput.macroset_hotkey).
 */
/proc/tgui_say_build_open_command(channel)
	return "\".output [TGUI_SAY_WINDOW_ID]:update [TGUI_SAY_OPEN_COMMAND][channel]\""

/client/proc/tgui_say_open_command(channel)
	return tgui_say_build_open_command(channel)

/**
 * Открывает панель ввода с сервера.
 *
 * Путь для клавиш, у которых нет клиентской команды, и для кода, который сам
 * зовёт ввод. Обычные каналы связи открываются без сервера.
 */
/client/proc/tgui_say_open(channel)
	if(!tgui_say?.window_ready)
		return FALSE
	ForceAllKeysUp()
	tgui_say.window.send_message("open", list("channel" = channel))
	return TRUE
