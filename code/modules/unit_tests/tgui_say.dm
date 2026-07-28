/// Каркас окна ввода сообщений: датум обязан переживать создание и удаление
/// без живого клиента, иначе его нельзя ни тестировать, ни безопасно чистить
/// при выходе игрока.
/datum/unit_test/tgui_say_lifecycle

/datum/unit_test/tgui_say_lifecycle/Run()
	var/datum/tgui_say/say_modal = new(null, null)
	TEST_ASSERT_EQUAL(say_modal.window_open, FALSE, "окно ввода считает себя открытым сразу после создания")
	TEST_ASSERT_EQUAL(say_modal.current_channel, TGUI_SAY_CHANNEL_SAY, "канал по умолчанию должен быть [TGUI_SAY_CHANNEL_SAY]")
	TEST_ASSERT_NULL(say_modal.window, "без клиента окно tgui создаваться не должно")
	qdel(say_modal)

/// Рукопожатие от загрузившегося окна обязано приводить состояние в закрытое:
/// иначе после переподключения сервер будет считать окно открытым и держать
/// индикатор печати.
/datum/unit_test/tgui_say_ready_handshake

/datum/unit_test/tgui_say_ready_handshake/Run()
	var/datum/tgui_say/say_modal = new(null, null)
	say_modal.window_open = TRUE
	say_modal.current_channel = TGUI_SAY_CHANNEL_OOC
	TEST_ASSERT(say_modal.on_message("ready", null), "окно ввода не обработало рукопожатие")
	TEST_ASSERT_EQUAL(say_modal.window_open, FALSE, "после рукопожатия окно должно считаться закрытым")
	TEST_ASSERT_EQUAL(say_modal.current_channel, TGUI_SAY_CHANNEL_SAY, "после рукопожатия канал должен вернуться к [TGUI_SAY_CHANNEL_SAY]")
	qdel(say_modal)

/// Неизвестный тип сообщения не должен молча считаться обработанным.
/datum/unit_test/tgui_say_unknown_message

/datum/unit_test/tgui_say_unknown_message/Run()
	var/datum/tgui_say/say_modal = new(null, null)
	TEST_ASSERT(!say_modal.on_message("нет такого типа", null), "окно ввода приняло неизвестный тип сообщения")
	qdel(say_modal)

/// Моб-пробник: запоминает, что до него дошло, вместо настоящего вывода речи.
/mob/living/carbon/human/tgui_say_probe
	var/last_say_message
	var/say_calls = 0
	var/last_whisper_message
	var/last_emote_act
	var/last_emote_message

/mob/living/carbon/human/tgui_say_probe/say(message, bubble_type, var/list/spans = list(), sanitize = TRUE, datum/language/language = null, ignore_spam = FALSE, forced = null)
	say_calls++
	last_say_message = message
	return TRUE

/mob/living/carbon/human/tgui_say_probe/whisper(message, bubble_type, list/spans = list(), sanitize = TRUE, datum/language/language = null, ignore_spam = FALSE, forced = null)
	last_whisper_message = message
	return TRUE

/mob/living/carbon/human/tgui_say_probe/emote(act, m_type = null, message = null, intentional = FALSE, message_override = null)
	last_emote_act = act
	last_emote_message = message
	return TRUE

/// Датум-пробник: живого клиента в юнит-тесте взять негде, поэтому источник
/// говорящего подменяется напрямую.
/datum/tgui_say/unit_test_probe
	var/mob/probe_mob

/datum/tgui_say/unit_test_probe/get_speaker()
	return probe_mob

/// Текст из окна обязан уходить в обычный путь речи, а не в отдельную копию логики.
/datum/unit_test/tgui_say_delegates_say

/datum/unit_test/tgui_say_delegates_say/Run()
	var/mob/living/carbon/human/tgui_say_probe/speaker = allocate(/mob/living/carbon/human/tgui_say_probe)
	var/datum/tgui_say/unit_test_probe/say_modal = new(null, null)
	say_modal.probe_mob = speaker

	TEST_ASSERT(say_modal.delegate_speech("тест связи", TGUI_SAY_CHANNEL_SAY), "канал [TGUI_SAY_CHANNEL_SAY] не принял текст")
	TEST_ASSERT_EQUAL(speaker.last_say_message, "тест связи", "канал [TGUI_SAY_CHANNEL_SAY] не довёл текст до say()")
	TEST_ASSERT(!say_modal.delegate_speech("мимо", "НетТакогоКанала"), "окно ввода приняло неизвестный канал")
	TEST_ASSERT_EQUAL(speaker.say_calls, 1, "неизвестный канал всё-таки дошёл до say()")

	qdel(say_modal)

/// Каждый канал обязан уходить в своё, а рация — с префиксом, который разберёт
/// обычный код речи.
/datum/unit_test/tgui_say_channel_routing

/datum/unit_test/tgui_say_channel_routing/Run()
	var/mob/living/carbon/human/tgui_say_probe/speaker = allocate(/mob/living/carbon/human/tgui_say_probe)
	var/datum/tgui_say/unit_test_probe/say_modal = new(null, null)
	say_modal.probe_mob = speaker

	TEST_ASSERT(say_modal.delegate_speech("на связи", TGUI_SAY_CHANNEL_RADIO), "канал рации не принял текст")
	TEST_ASSERT_EQUAL(speaker.last_say_message, "[TGUI_SAY_RADIO_TOKEN]на связи", "канал рации потерял префикс общего канала")

	TEST_ASSERT(say_modal.delegate_speech("тихо", TGUI_SAY_CHANNEL_WHISPER), "шёпот не принял текст")
	TEST_ASSERT_EQUAL(speaker.last_whisper_message, "тихо", "шёпот не дошёл до whisper()")

	TEST_ASSERT(say_modal.delegate_speech("машет рукой", TGUI_SAY_CHANNEL_ME), "эмоут не принял текст")
	TEST_ASSERT_EQUAL(speaker.last_emote_act, "me", "эмоут ушёл не в тот act")
	TEST_ASSERT_EQUAL(speaker.last_emote_message, "машет рукой", "эмоут потерял текст")

	TEST_ASSERT(say_modal.delegate_speech("шепчет на ухо", TGUI_SAY_CHANNEL_SUBTLE), "subtle не принял текст")
	TEST_ASSERT_EQUAL(speaker.last_emote_act, "subtle", "subtle ушёл не в тот act")

	TEST_ASSERT(say_modal.delegate_speech("незаметно", TGUI_SAY_CHANNEL_SUBTLER), "subtler не принял текст")
	TEST_ASSERT_EQUAL(speaker.last_emote_act, "subtler", "subtler ушёл не в тот act")

	TEST_ASSERT(say_modal.delegate_speech("дверь скрипит", TGUI_SAY_CHANNEL_NARRATE), "нарратив не принял текст")
	TEST_ASSERT_EQUAL(speaker.last_emote_act, "narrate", "нарратив ушёл не в тот act")
	TEST_ASSERT_EQUAL(speaker.last_emote_message, "дверь скрипит", "нарратив потерял текст")

	TEST_ASSERT(say_modal.delegate_speech("шорох за стеной", TGUI_SAY_CHANNEL_NARRATE_SUBTLER), "скрытый нарратив не принял текст")
	TEST_ASSERT_EQUAL(speaker.last_emote_act, "narrate_subtler", "скрытый нарратив ушёл не в тот act")

	qdel(say_modal)

/// Молитва — не внутриигровая речь: над игроком не должен висеть пузырь, а
/// блокировка речи администрацией её не касается.
/datum/unit_test/tgui_say_pray_channel

/datum/unit_test/tgui_say_pray_channel/Run()
	var/datum/tgui_say/unit_test_probe/say_modal = new(null, null)

	TEST_ASSERT(!say_modal.is_ic_channel(TGUI_SAY_CHANNEL_PRAY), "молитва считается внутриигровой речью")
	TEST_ASSERT(!say_modal.is_emote_channel(TGUI_SAY_CHANNEL_PRAY), "молитва показывает пузырь эмоции")
	TEST_ASSERT(say_modal.is_emote_channel(TGUI_SAY_CHANNEL_NARRATE), "нарратив не показывает пузырь эмоции")

	qdel(say_modal)

/// Индикатор печати обязан зажигаться по первому набранному символу, а не по
/// факту открытия окна, и гаснуть при закрытии. Иначе пузырь висит над теми,
/// кто открыл окно и передумал.
/datum/unit_test/tgui_say_typing_indicator

/datum/unit_test/tgui_say_typing_indicator/Run()
	var/mob/living/carbon/human/typist = allocate(/mob/living/carbon/human)
	var/datum/tgui_say/unit_test_probe/say_modal = new(null, null)
	say_modal.probe_mob = typist

	say_modal.on_message("open", list("channel" = TGUI_SAY_CHANNEL_SAY))
	TEST_ASSERT_NULL(typist.typing_indicator_current, "индикатор зажёгся до первого символа")

	say_modal.on_message("typing", null)
	TEST_ASSERT_NOTNULL(typist.typing_indicator_current, "индикатор не зажёгся при наборе")

	say_modal.on_message("close", null)
	TEST_ASSERT_NULL(typist.typing_indicator_current, "индикатор не погас при закрытии окна")

	qdel(say_modal)

/// В OOC-каналах индикатор печати не показывается: окружающие не должны знать,
/// что человек пишет вне игры.
/datum/unit_test/tgui_say_typing_indicator_ooc

/datum/unit_test/tgui_say_typing_indicator_ooc/Run()
	var/mob/living/carbon/human/typist = allocate(/mob/living/carbon/human)
	var/datum/tgui_say/unit_test_probe/say_modal = new(null, null)
	say_modal.probe_mob = typist

	say_modal.on_message("open", list("channel" = TGUI_SAY_CHANNEL_OOC))
	say_modal.on_message("typing", null)
	TEST_ASSERT_NULL(typist.typing_indicator_current, "индикатор зажёгся в OOC-канале")

	qdel(say_modal)

/// Пока человек печатает, окно шлёт сигнал заново — индикатор обязан
/// продлеваться, иначе на длинном сообщении он погаснет по таймауту.
/datum/unit_test/tgui_say_typing_indicator_refresh

/datum/unit_test/tgui_say_typing_indicator_refresh/Run()
	var/mob/living/carbon/human/typist = allocate(/mob/living/carbon/human)
	var/datum/tgui_say/unit_test_probe/say_modal = new(null, null)
	say_modal.probe_mob = typist

	say_modal.on_message("open", list("channel" = TGUI_SAY_CHANNEL_SAY))
	say_modal.on_message("typing", null)
	var/first_timer = typist.typing_indicator_timerid
	TEST_ASSERT_NOTNULL(first_timer, "индикатор зажёгся без таймера очистки")

	say_modal.on_message("typing", null)
	TEST_ASSERT_NOTEQUAL(typist.typing_indicator_timerid, first_timer, "повторный сигнал набора не продлил индикатор")
	TEST_ASSERT_NOTNULL(typist.typing_indicator_current, "повторный сигнал набора погасил индикатор")

	qdel(say_modal)

/// Внутриигровые каналы отделены от OOC: по этому признаку работает и блокировка
/// речи администрацией, и индикатор печати.
/datum/unit_test/tgui_say_ic_channels

/datum/unit_test/tgui_say_ic_channels/Run()
	var/datum/tgui_say/unit_test_probe/say_modal = new(null, null)

	TEST_ASSERT(say_modal.is_ic_channel(TGUI_SAY_CHANNEL_SAY), "[TGUI_SAY_CHANNEL_SAY] должен считаться внутриигровым")
	TEST_ASSERT(say_modal.is_ic_channel(TGUI_SAY_CHANNEL_ME), "[TGUI_SAY_CHANNEL_ME] должен считаться внутриигровым")
	TEST_ASSERT(say_modal.is_ic_channel(TGUI_SAY_CHANNEL_RADIO), "[TGUI_SAY_CHANNEL_RADIO] должен считаться внутриигровым")
	TEST_ASSERT(!say_modal.is_ic_channel(TGUI_SAY_CHANNEL_OOC), "[TGUI_SAY_CHANNEL_OOC] не должен считаться внутриигровым")
	TEST_ASSERT(!say_modal.is_ic_channel(TGUI_SAY_CHANNEL_LOOC), "[TGUI_SAY_CHANNEL_LOOC] не должен считаться внутриигровым")
	TEST_ASSERT(!say_modal.is_ic_channel(TGUI_SAY_CHANNEL_AOOC), "[TGUI_SAY_CHANNEL_AOOC] не должен считаться внутриигровым")

	qdel(say_modal)

/// Пустой текст и текст сверх предела до речи доходить не должны.
/datum/unit_test/tgui_say_entry_guards

/datum/unit_test/tgui_say_entry_guards/Run()
	var/mob/living/carbon/human/tgui_say_probe/speaker = allocate(/mob/living/carbon/human/tgui_say_probe)
	var/datum/tgui_say/unit_test_probe/say_modal = new(null, null)
	say_modal.probe_mob = speaker
	say_modal.max_length = 10

	TEST_ASSERT(!say_modal.handle_entry(list("channel" = TGUI_SAY_CHANNEL_SAY, "entry" = "")), "пустое сообщение было принято")
	TEST_ASSERT(!say_modal.handle_entry(list("channel" = TGUI_SAY_CHANNEL_SAY, "entry" = "сообщение длиннее предела")), "сообщение сверх предела было принято")
	TEST_ASSERT(!say_modal.handle_entry(list("entry" = "без канала")), "сообщение без канала было принято")
	TEST_ASSERT_EQUAL(speaker.say_calls, 0, "отбитое сообщение всё-таки дошло до say()")

	TEST_ASSERT(say_modal.handle_entry(list("channel" = TGUI_SAY_CHANNEL_SAY, "entry" = "норма")), "нормальное сообщение было отбито")
	TEST_ASSERT_EQUAL(speaker.say_calls, 1, "нормальное сообщение не дошло до say()")

	qdel(say_modal)

/// Команда открытия уходит в макрос клавиши, а параметры winset разделяются
/// в том числе пробелом: без кавычек команда обрезается по первому пробелу и
/// клавиша перестаёт открывать панель вовсе.
/datum/unit_test/tgui_say_open_command_quoted

/datum/unit_test/tgui_say_open_command_quoted/Run()
	var/command = tgui_say_build_open_command(TGUI_SAY_CHANNEL_OOC)

	TEST_ASSERT(findtext(command, " "), "в команде открытия не осталось пробела — проверять нечего")
	TEST_ASSERT_EQUAL(copytext(command, 1, 2), "\"", "команда открытия не начинается с кавычки")
	TEST_ASSERT_EQUAL(copytext(command, -1), "\"", "команда открытия не заканчивается кавычкой")
	TEST_ASSERT(findtext(command, "[TGUI_SAY_OPEN_COMMAND][TGUI_SAY_CHANNEL_OOC]"), "команда открытия не несёт канал")
	TEST_ASSERT(findtext(command, TGUI_SAY_WINDOW_ID), "команда открытия не адресована панели ввода")

/// Пока бандл не загрузился, панель нельзя ни открыть, ни спрятать: сообщение
/// просто некому принять, а игрок остался бы без речи.
/datum/unit_test/tgui_say_hide_requires_ready

/datum/unit_test/tgui_say_hide_requires_ready/Run()
	var/datum/tgui_say/say_modal = new(null, null)

	TEST_ASSERT(!say_modal.hide(), "незагруженная панель согласилась прятаться")

	say_modal.window_ready = TRUE
	// Окна tgui без клиента нет, поэтому дальше hide() ничего не отправит —
	// проверяем именно снятие блокировки по готовности.
	TEST_ASSERT(say_modal.hide(), "загруженная панель отказалась прятаться")

	qdel(say_modal)

/// Рукопожатие обязано отмечать панель загруженной: по этому признаку клавиши
/// переводятся на прямое открытие.
/datum/unit_test/tgui_say_ready_marks_loaded

/datum/unit_test/tgui_say_ready_marks_loaded/Run()
	var/datum/tgui_say/say_modal = new(null, null)

	TEST_ASSERT(!say_modal.window_ready, "панель считает себя загруженной до рукопожатия")
	say_modal.on_message("ready", null)
	TEST_ASSERT(say_modal.window_ready, "после рукопожатия панель не отмечена загруженной")

	qdel(say_modal)

/// Подсказки по рациям строятся по тем же данным, что и разбор речи: в них не
/// может оказаться канала, в который говорить нельзя, и не может потеряться
/// канал, который у игрока есть.
/datum/unit_test/tgui_say_radio_hints

/datum/unit_test/tgui_say_radio_hints/Run()
	var/mob/living/carbon/human/speaker = allocate(/mob/living/carbon/human)
	var/datum/tgui_say/unit_test_probe/say_modal = new(null, null)
	say_modal.probe_mob = speaker

	TEST_ASSERT_EQUAL(length(say_modal.get_radio_hints()), 0, "подсказки по рациям нашлись без самой рации")

	var/obj/item/radio/headset/headset = allocate(/obj/item/radio/headset/headset_sec)
	speaker.equip_to_slot_or_del(headset, ITEM_SLOT_EARS_LEFT)
	TEST_ASSERT_EQUAL(speaker.ears, headset, "гарнитура не надета — проверять нечего")

	var/list/tokens = list()
	for(var/list/hint in say_modal.get_radio_hints())
		tokens += hint["token"]

	TEST_ASSERT((RADIO_KEY_COMMON in tokens), "в подсказках нет общего канала")
	TEST_ASSERT((MODE_TOKEN_DEPARTMENT in tokens), "в подсказках нет канала своего отдела")
	TEST_ASSERT((RADIO_TOKEN_SECURITY in tokens), "в подсказках нет канала гарнитуры СБ")
	TEST_ASSERT(!(RADIO_TOKEN_SYNDICATE in tokens), "в подсказках оказался канал, которого у игрока нет")

	qdel(say_modal)

/// Открытие и закрытие обязаны вести состояние канала, иначе после закрытия
/// сервер продолжит считать игрока печатающим.
/datum/unit_test/tgui_say_open_close_state

/datum/unit_test/tgui_say_open_close_state/Run()
	var/datum/tgui_say/unit_test_probe/say_modal = new(null, null)

	TEST_ASSERT(say_modal.open(list("channel" = TGUI_SAY_CHANNEL_ME)), "окно не открылось")
	TEST_ASSERT_EQUAL(say_modal.window_open, TRUE, "после открытия окно не считается открытым")
	TEST_ASSERT_EQUAL(say_modal.current_channel, TGUI_SAY_CHANNEL_ME, "канал открытия не запомнен")

	TEST_ASSERT(say_modal.close(), "окно не закрылось")
	TEST_ASSERT_EQUAL(say_modal.window_open, FALSE, "после закрытия окно считается открытым")

	qdel(say_modal)
