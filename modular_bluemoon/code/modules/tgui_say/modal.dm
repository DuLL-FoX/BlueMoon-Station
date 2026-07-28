/// Способы ввода сообщений, доступные игроку в настройках.
GLOBAL_LIST_INIT(say_input_modes, list(
	SAY_INPUT_MODE_WINDOW,
	SAY_INPUT_MODE_NATIVE,
	SAY_INPUT_MODE_MODAL,
))

/// Места, куда игрок может поставить панель ввода.
GLOBAL_LIST_INIT(say_input_anchors, list(
	SAY_INPUT_ANCHOR_HUD,
	SAY_INPUT_ANCHOR_BOTTOM,
	SAY_INPUT_ANCHOR_TOP,
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
	window?.send_message("props", get_props())
	return TRUE

/**
 * Параметры панели.
 *
 * Уезжают целиком и при загрузке, и при каждом открытии: между открытиями
 * игрок мог снять гарнитуру, сменить настройку или пересесть за другого моба.
 */
/datum/tgui_say/proc/get_props()
	return list(
		"maxLength" = max_length,
		"emotes" = get_emote_keys(),
		"anchor" = client?.prefs?.say_input_anchor || SAY_INPUT_ANCHOR_HUD,
		"viewTiles" = get_view_tiles(),
		"hudTiles" = TGUI_SAY_HUD_TILES,
		"radios" = get_radio_hints(),
		"languages" = get_language_hints(),
	)

/**
 * Высота обзора в клетках.
 *
 * По ней фронт считает, сколько пикселей карты занимает клетка, а значит и
 * панель действий, над которой садится ввод.
 */
/datum/tgui_say/proc/get_view_tiles()
	var/list/size = getviewsize(client?.view || world.view)
	return size[2]

/// Рации, до которых говорящий реально может дотянуться.
/datum/tgui_say/proc/collect_radios()
	var/list/radios = list()
	var/mob/living/speaker = get_speaker()
	if(!isliving(speaker))
		return radios
	var/obj/item/implant/radio/implant = locate() in speaker.implants
	if(implant?.radio?.on)
		radios += implant.radio
	if(ishuman(speaker))
		var/mob/living/carbon/human/human_speaker = speaker
		if(istype(human_speaker.ears, /obj/item/radio))
			radios += human_speaker.ears
		if(istype(human_speaker.ears_extra, /obj/item/radio))
			radios += human_speaker.ears_extra
	else if(issilicon(speaker))
		var/mob/living/silicon/silicon_speaker = speaker
		if(silicon_speaker.radio)
			radios += silicon_speaker.radio
	return radios

/**
 * Подсказки по рациям: префикс и название канала.
 *
 * Список строится по тем же данным, что и разбор речи, поэтому в подсказках не
 * может оказаться канала, в который говорить нельзя.
 */
/datum/tgui_say/proc/get_radio_hints()
	var/list/hints = list()
	var/list/seen = list()
	for(var/obj/item/radio/radio as anything in collect_radios())
		if(!radio.on)
			continue
		if(!seen[RADIO_KEY_COMMON])
			seen[RADIO_KEY_COMMON] = TRUE
			hints += list(list("token" = RADIO_KEY_COMMON, "name" = "Общий"))
		var/first_channel = TRUE
		for(var/channel_name in radio.channels)
			if(!radio.channels[channel_name])
				continue
			// Первый канал гарнитуры — это и есть ":h", "свой отдел".
			if(first_channel)
				first_channel = FALSE
				if(!seen[MODE_TOKEN_DEPARTMENT])
					seen[MODE_TOKEN_DEPARTMENT] = TRUE
					hints += list(list("token" = MODE_TOKEN_DEPARTMENT, "name" = "Отдел"))
			var/token = GLOB.channel_tokens[channel_name]
			if(!token || seen[token])
				continue
			seen[token] = TRUE
			hints += list(list("token" = token, "name" = channel_name))
	return hints

/// Подсказки по языкам: префикс запятой и название.
/datum/tgui_say/proc/get_language_hints()
	var/list/hints = list()
	var/mob/living/speaker = get_speaker()
	if(!isliving(speaker))
		return hints
	var/datum/language_holder/holder = speaker.get_language_holder()
	if(!holder)
		return hints
	for(var/datum/language/language as anything in holder.spoken_languages)
		if(!holder.can_speak_language(language))
			continue
		var/key = initial(language.key)
		if(!key)
			continue
		hints += list(list("token" = ",[key]", "name" = initial(language.name)))
	return hints

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
	// Гарнитуру могли снять, а настройку — сменить: подсказки и место панели
	// обновляем на каждом открытии, панель этого не ждёт.
	if(client)
		window?.send_message("props", get_props())
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
