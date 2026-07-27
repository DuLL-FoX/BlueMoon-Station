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
