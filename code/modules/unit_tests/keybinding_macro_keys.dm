/// Привязки хранятся слитно ("CtrlShiftT"), а макросы BYOND ждут ключ через
/// плюсы и в строго определённом порядке модификаторов. Порядок важен: списки
/// этих строк вычитаются друг из друга при сборке анти-коллизии.
/datum/unit_test/keybind_macro_key_format

/datum/unit_test/keybind_macro_key_format/Run()
	TEST_ASSERT_EQUAL(keybind_strip_modifiers("CtrlShiftT"), "T", "модификаторы не отделились от ключа")
	TEST_ASSERT_EQUAL(keybind_strip_modifiers("T"), "T", "ключ без модификаторов не должен меняться")

	TEST_ASSERT_EQUAL(keybind_to_macro_key("T"), "T", "ключ без модификаторов не должен обрастать плюсами")
	TEST_ASSERT_EQUAL(keybind_to_macro_key("CtrlT"), "Ctrl+T", "Ctrl не встал в макрос-ключ")
	TEST_ASSERT_EQUAL(keybind_to_macro_key("AltShiftF"), "Alt+Shift+F", "порядок модификаторов разошёлся с ожидаемым")
	TEST_ASSERT_EQUAL(keybind_to_macro_key("CtrlShiftAltQ"), "Alt+Ctrl+Shift+Q", "порядок модификаторов разошёлся с ожидаемым")

/**
 * Анти-коллизия макросов забивает пустышкой все комбинации клавиши, кроме той,
 * что назначена. В список попадает и голая клавиша: Ctrl+T глушил обычную T,
 * из-за чего Say с индикатором переставал открываться вовсе. Поэтому назначенные
 * игроком комбинации из списка вычитаются.
 */
/datum/unit_test/keybind_permutation_covers_bare_key

/datum/unit_test/keybind_permutation_covers_bare_key/Run()
	var/list/overriding = keybind_modifier_permutation("T", FALSE, TRUE, FALSE, TRUE)

	TEST_ASSERT(("T" in overriding), "перестановки Ctrl+T перестали задевать голую T — тест устарел")
	TEST_ASSERT(("Shift+T" in overriding), "перестановки Ctrl+T не покрывают Shift+T")
	TEST_ASSERT(!("Ctrl+T" in overriding), "перестановки Ctrl+T включают саму себя")

	// Ровно это вычитание и защищает назначенные клавиши.
	var/list/explicit = list(keybind_to_macro_key("T"), keybind_to_macro_key("CtrlT"))
	overriding -= explicit
	TEST_ASSERT(!("T" in overriding), "назначенная клавиша осталась под пустышкой")
	TEST_ASSERT(("Shift+T" in overriding), "вычитание назначенных клавиш убрало лишнее")
