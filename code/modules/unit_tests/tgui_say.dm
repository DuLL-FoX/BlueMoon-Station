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

/mob/living/carbon/human/tgui_say_probe/say(message, bubble_type, var/list/spans = list(), sanitize = TRUE, datum/language/language = null, ignore_spam = FALSE, forced = null)
	say_calls++
	last_say_message = message
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
