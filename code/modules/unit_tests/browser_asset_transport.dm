/datum/unit_test/browser_asset_transport/Run()
	var/datum/asset/simple/jquery/jquery_assets = get_asset_datum(/datum/asset/simple/jquery)
	TEST_ASSERT(!jquery_assets.legacy, "jQuery must use the configured asset transport")

	var/datum/asset/simple/namespaced/bluemoon_tooltip/tooltip_assets = get_asset_datum(/datum/asset/simple/namespaced/bluemoon_tooltip)
	var/list/tooltip_urls = tooltip_assets.get_url_mappings()
	TEST_ASSERT(length(tooltip_urls["tooltip.html"]), "tooltip HTML must have a transport URL")
	TEST_ASSERT(length(tooltip_urls["tooltip-jquery.min.js"]), "tooltip jQuery must have a transport URL")
	TEST_ASSERT(length(tooltip_urls["tooltip-SpaceMono.ttf"]), "tooltip font must have a transport URL")

	var/datum/asset/group/irv/irv_assets = get_asset_datum(/datum/asset/group/irv)
	var/list/irv_urls = irv_assets.get_url_mappings()
	TEST_ASSERT(length(irv_urls["jquery.min.js"]), "IRV jQuery must have a transport URL")
	TEST_ASSERT(length(irv_urls["jquery-ui.custom-core-widgit-mouse-sortable-min.js"]), "IRV sortable script must have a transport URL")

	var/datum/asset/simple/namespaced/bluemoon_statbrowser/statbrowser_assets = get_asset_datum(/datum/asset/simple/namespaced/bluemoon_statbrowser)
	var/list/statbrowser_urls = statbrowser_assets.get_url_mappings()
	TEST_ASSERT(length(statbrowser_urls["statbrowser.html"]), "statbrowser HTML must have a transport URL")

/// Инвалидация URL двигает поколение, сбрасывает кеш сериализованных url_mappings
/// и адрес JS лобби: всё это выдано прежним транспортом и без сброса переживает
/// его смену (см. Toggle CDN и fallback_to_simple_transport).
/datum/unit_test/asset_url_invalidation_rebuilds_mappings/Run()
	var/datum/asset/simple/namespaced/bluemoon_tooltip/tooltip_assets = get_asset_datum(/datum/asset/simple/namespaced/bluemoon_tooltip)
	tooltip_assets.get_serialized_url_mappings()
	TEST_ASSERT_NOTNULL(tooltip_assets.cached_url_mappings, "Прогрев не заполнил кеш url_mappings")
	var/saved_lobby_js_url = SStitle_bm?.cached_js_url
	if (SStitle_bm)
		SStitle_bm.cached_js_url = "stale://sentinel"
	var/generation_before = GLOB.asset_url_generation

	SSassets.invalidate_asset_urls()

	TEST_ASSERT_EQUAL(GLOB.asset_url_generation, generation_before + 1, "Инвалидация не сдвинула поколение URL")
	TEST_ASSERT_NULL(tooltip_assets.cached_url_mappings, "Инвалидация не сбросила кеш url_mappings")
	if (SStitle_bm)
		TEST_ASSERT_EQUAL(SStitle_bm.cached_js_url, "", "Инвалидация не сбросила кешированный адрес JS лобби")
		SStitle_bm.cached_js_url = saved_lobby_js_url
	tooltip_assets.get_serialized_url_mappings()
	TEST_ASSERT_EQUAL(tooltip_assets.cached_url_mappings_generation, GLOB.asset_url_generation, "Пересборка не проштамповала кеш новым поколением")

/// Аварийный фолбэк webroot-транспорта: подменяет активный транспорт на раздачу
/// через DreamDaemon, считает срыв ровно один раз и инвалидирует выданные URL.
/// Повторный сигнал того же сбоя счётчик двигать не должен.
/datum/unit_test/asset_transport_fallback_invalidation/Run()
	var/datum/asset_transport/saved_transport = SSassets.transport
	var/saved_fallbacks = GLOB.asset_transport_fallbacks
	var/saved_reason = GLOB.asset_transport_fallback_reason
	var/saved_time = GLOB.asset_transport_fallback_time
	var/datum/asset_transport/webroot/webroot_transport = new
	SSassets.transport = webroot_transport
	var/generation_before = GLOB.asset_url_generation

	webroot_transport.fallback_to_simple_transport("unit test: primary failure")

	TEST_ASSERT(!istype(SSassets.transport, /datum/asset_transport/webroot), "После фолбэка транспорт остался webroot")
	TEST_ASSERT_EQUAL(GLOB.asset_transport_fallbacks, saved_fallbacks + 1, "Фолбэк не посчитал срыв")
	TEST_ASSERT_EQUAL(GLOB.asset_transport_fallback_reason, "unit test: primary failure", "Фолбэк не записал причину срыва")
	TEST_ASSERT_EQUAL(GLOB.asset_url_generation, generation_before + 1, "Фолбэк не инвалидировал выданные URL")

	webroot_transport.fallback_to_simple_transport("unit test: duplicate signal")
	TEST_ASSERT_EQUAL(GLOB.asset_transport_fallbacks, saved_fallbacks + 1, "Повторный сигнал одного сбоя посчитан вторым срывом")
	TEST_ASSERT_EQUAL(GLOB.asset_url_generation, generation_before + 1, "Повторный сигнал одного сбоя инвалидировал URL второй раз")

	SSassets.transport = saved_transport
	GLOB.asset_transport_fallbacks = saved_fallbacks
	GLOB.asset_transport_fallback_reason = saved_reason
	GLOB.asset_transport_fallback_time = saved_time

/// The production setup bundle contains the placeholder as a JavaScript sentinel.
/// Rendering must replace only the meta value or every window resets its real id to null.
/datum/unit_test/tgui_bootstrap_window_id_rendering/Run()
	var/template = file2text('tgui/public/tgui.html')
	var/setup_script = file2text('tgui/public/tgui-setup.bundle.js')
	var/base_html = replacetextEx(template, "<!-- tgui:setup -->", setup_script)
	var/placeholder = "\[tgui:windowId]"
	var/placeholders_before = _count_occurrences(base_html, placeholder)
	TEST_ASSERT(placeholders_before >= 1, "the TGUI base template must contain a window-id placeholder")

	var/rendered = tgui_inject_window_id(base_html, "test-window")
	TEST_ASSERT(findtext(rendered, "content=\"test-window\""), "the TGUI renderer must inject the window id into its meta tag")
	TEST_ASSERT(!findtext(rendered, "content=\"\[tgui:windowId]\""), "the rendered meta tag must not retain its placeholder")
	TEST_ASSERT_EQUAL(_count_occurrences(rendered, placeholder), placeholders_before - 1, "rendering must leave bootstrap sentinel occurrences untouched")
