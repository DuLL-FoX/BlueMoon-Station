/// Первое открытие мессенджера: ui_data() зовёт get_emoji_list(), а сразу за ним
/// get_emoji_urls(). Раньше второй вызов затирал только что собранные адреса и
/// ничего не строил взамен, так что панель эмодзи весь раунд показывала ":smile:"
/// текстом.
/datum/unit_test/emoji_urls_survive_first_open/Run()
	var/list/saved_names = GLOB.cached_emoji_list
	var/list/saved_urls = GLOB.cached_emoji_urls
	var/list/saved_asset_names = GLOB.cached_emoji_asset_names
	var/list/saved_assets_by_name = GLOB.cached_emoji_asset_by_name
	var/saved_generation = GLOB.cached_emoji_url_generation

	// Состояние сразу после старта раунда: кеш пуст, поколение заведомо чужое.
	GLOB.cached_emoji_list = list()
	GLOB.cached_emoji_urls = list()
	GLOB.cached_emoji_asset_names = list()
	GLOB.cached_emoji_asset_by_name = list()
	GLOB.cached_emoji_url_generation = GLOB.asset_url_generation - 1

	var/list/emoji_names = get_emoji_list()
	var/list/emoji_urls = get_emoji_urls()
	var/first_emoji = length(emoji_names) ? emoji_names[1] : null
	var/first_url = first_emoji ? emoji_urls[first_emoji] : null
	var/url_count = length(emoji_urls)
	var/asset_count = length(GLOB.cached_emoji_asset_names)

	GLOB.cached_emoji_list = saved_names
	GLOB.cached_emoji_urls = saved_urls
	GLOB.cached_emoji_asset_names = saved_asset_names
	GLOB.cached_emoji_asset_by_name = saved_assets_by_name
	GLOB.cached_emoji_url_generation = saved_generation

	TEST_ASSERT(length(emoji_names), "Список имён эмодзи пуст")
	TEST_ASSERT(url_count, "После get_emoji_list() и get_emoji_urls() словарь адресов эмодзи пуст")
	TEST_ASSERT(asset_count, "Список имён ассетов эмодзи пуст - клиенту нечего отправлять")
	TEST_ASSERT_NOTNULL(first_url, "У эмодзи «[first_emoji]» нет адреса ассета")

/// Срыв транспорта с CDN двигает GLOB.asset_url_generation: выданные прежним
/// транспортом адреса мертвы, и кеш обязан пересобраться под новый.
/datum/unit_test/emoji_urls_rebuild_after_transport_change/Run()
	var/list/saved_names = GLOB.cached_emoji_list
	var/list/saved_urls = GLOB.cached_emoji_urls
	var/list/saved_asset_names = GLOB.cached_emoji_asset_names
	var/list/saved_assets_by_name = GLOB.cached_emoji_asset_by_name
	var/saved_generation = GLOB.cached_emoji_url_generation
	var/saved_transport_generation = GLOB.asset_url_generation

	GLOB.cached_emoji_list = list()
	GLOB.cached_emoji_urls = list()
	GLOB.cached_emoji_asset_names = list()
	GLOB.cached_emoji_asset_by_name = list()
	GLOB.cached_emoji_url_generation = GLOB.asset_url_generation - 1

	get_emoji_list()
	var/urls_before = length(get_emoji_urls())

	GLOB.asset_url_generation++
	var/urls_after = length(get_emoji_urls())
	var/stamped_generation = GLOB.cached_emoji_url_generation
	var/expected_generation = GLOB.asset_url_generation

	GLOB.cached_emoji_list = saved_names
	GLOB.cached_emoji_urls = saved_urls
	GLOB.cached_emoji_asset_names = saved_asset_names
	GLOB.cached_emoji_asset_by_name = saved_assets_by_name
	GLOB.cached_emoji_url_generation = saved_generation
	GLOB.asset_url_generation = saved_transport_generation

	TEST_ASSERT(urls_before, "Адреса эмодзи не собрались до смены поколения")
	TEST_ASSERT_EQUAL(urls_after, urls_before, "После смены поколения адресов эмодзи стало меньше")
	TEST_ASSERT_EQUAL(stamped_generation, expected_generation, "Кеш адресов эмодзи не отметил поколение, под которое собран")

/// parse_emoji_message() читал кеш адресов напрямую, мимо проверки поколения:
/// на протухшем кеше сообщение уезжало с голым ":smile:" вместо картинки.
/datum/unit_test/emoji_message_substitutes_image/Run()
	var/list/saved_names = GLOB.cached_emoji_list
	var/list/saved_urls = GLOB.cached_emoji_urls
	var/list/saved_asset_names = GLOB.cached_emoji_asset_names
	var/list/saved_assets_by_name = GLOB.cached_emoji_asset_by_name
	var/saved_generation = GLOB.cached_emoji_url_generation

	GLOB.cached_emoji_list = list()
	GLOB.cached_emoji_urls = list()
	GLOB.cached_emoji_asset_names = list()
	GLOB.cached_emoji_asset_by_name = list()
	GLOB.cached_emoji_url_generation = GLOB.asset_url_generation - 1

	var/list/emoji_names = get_emoji_list()
	var/first_emoji = length(emoji_names) ? emoji_names[1] : null
	// Кеш адресов намеренно оставлен протухшим - ровно так он выглядит после
	// срыва транспорта посреди раунда.
	GLOB.cached_emoji_urls = list()
	GLOB.cached_emoji_url_generation = GLOB.asset_url_generation - 1
	var/parsed = first_emoji ? parse_emoji_message("тест :[first_emoji]: тест") : null

	GLOB.cached_emoji_list = saved_names
	GLOB.cached_emoji_urls = saved_urls
	GLOB.cached_emoji_asset_names = saved_asset_names
	GLOB.cached_emoji_asset_by_name = saved_assets_by_name
	GLOB.cached_emoji_url_generation = saved_generation

	TEST_ASSERT_NOTNULL(first_emoji, "Список имён эмодзи пуст")
	TEST_ASSERT(findtext(parsed, "<img"), "parse_emoji_message() не подставил картинку эмодзи: [parsed]")

/// Зрителю уходят ассеты только тех эмодзи, что реально есть в сообщении: полный
/// набор - это около двух сотен browse_rsc на клиента в один тик, а гостов в
/// раунде бывает под полсотни.
/datum/unit_test/emoji_message_assets_are_targeted/Run()
	var/list/saved_names = GLOB.cached_emoji_list
	var/list/saved_urls = GLOB.cached_emoji_urls
	var/list/saved_asset_names = GLOB.cached_emoji_asset_names
	var/list/saved_assets_by_name = GLOB.cached_emoji_asset_by_name
	var/saved_generation = GLOB.cached_emoji_url_generation

	GLOB.cached_emoji_list = list()
	GLOB.cached_emoji_urls = list()
	GLOB.cached_emoji_asset_names = list()
	GLOB.cached_emoji_asset_by_name = list()
	GLOB.cached_emoji_url_generation = GLOB.asset_url_generation - 1

	var/list/emoji_names = get_emoji_list()
	var/first_emoji = length(emoji_names) ? emoji_names[1] : null
	var/parsed = first_emoji ? parse_emoji_message("тест :[first_emoji]: тест") : null
	var/list/needed_assets = parsed ? get_message_emoji_assets(parsed) : null
	var/list/assets_for_plain_text = get_message_emoji_assets("сообщение без единой картинки")
	var/full_set_size = length(GLOB.cached_emoji_asset_names)

	GLOB.cached_emoji_list = saved_names
	GLOB.cached_emoji_urls = saved_urls
	GLOB.cached_emoji_asset_names = saved_asset_names
	GLOB.cached_emoji_asset_by_name = saved_assets_by_name
	GLOB.cached_emoji_url_generation = saved_generation

	TEST_ASSERT_NOTNULL(first_emoji, "Список имён эмодзи пуст")
	TEST_ASSERT_EQUAL(length(needed_assets), 1, "Для сообщения с одним эмодзи набрался не один ассет")
	TEST_ASSERT_NULL(assets_for_plain_text, "Сообщение без картинок всё равно потребовало ассетов")
	TEST_ASSERT(full_set_size > length(needed_assets), "Полный набор ассетов эмодзи не больше точечного - сравнивать нечего")
