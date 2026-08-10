// Regression tests for world-blocking HTTP in hot paths: world.Export("http://...")
// performs the whole request on the main thread — the ENTIRE world freezes until the
// remote endpoint answers or times out (~10s+), and `set waitfor = FALSE` does NOT
// help (the block happens inside the native call, before any sleep). Production round
// on 6604475cc1 caught a 10.3s full-world freeze at roundstart from exactly this.
//
// The replacement is rustg async http (/proc/world_safe_http_get): the calling proc
// sleeps while polling, the world keeps ticking.
//
// Source-level checks via read_source_file: actually exercising these procs needs a
// real client + reachable byond.com, so we verify the structural invariant instead.

/// Locate proc body in source text by header. Returns the substring from the header
/// to the next declaration at column 0 with the given prefix (or end of file).
/datum/unit_test/proc/_extract_proc_body(source, header, next_decl_prefix = "\n/client/proc/")
	var/start = findtext(source, header)
	if(!start)
		return null
	var/search_from = start + length(header)
	var/end = findtext(source, next_decl_prefix, search_from)
	if(!end)
		end = length(source) + 1
	return copytext(source, start, end)

/// Counts non-overlapping occurrences of needle in haystack.
/datum/unit_test/proc/_count_occurrences(haystack, needle)
	var/count = 0
	var/pos = findtext(haystack, needle)
	while(pos)
		count++
		pos = findtext(haystack, needle, pos + length(needle))
	return count

/datum/unit_test/login_validate_key_in_db_is_async/Run()
	var/source = read_source_file("code/modules/client/client_procs.dm")
	TEST_ASSERT(length(source) > 1000, "client_procs.dm must be readable from the test working directory or parent checkout (got [length(source)] chars)")

	var/body = _extract_proc_body(source, "/client/proc/validate_key_in_db()")
	TEST_ASSERT_NOTNULL(body, "/client/proc/validate_key_in_db() must exist in client_procs.dm")

	// Fire-and-forget: must still detach from /client/New() at its first sleep.
	TEST_ASSERT(findtext(body, "set waitfor = FALSE"), "/client/proc/validate_key_in_db must declare 'set waitfor = FALSE' — its byond.com request must not block /client/New()")
	// And the request itself must not hold the world: rustg async, not world.Export.
	TEST_ASSERT(!findtext(body, "world.Export("), "/client/proc/validate_key_in_db must not call world.Export() — it freezes the entire world for the whole HTTP round-trip")
	TEST_ASSERT(findtext(body, "world_safe_http_get("), "/client/proc/validate_key_in_db must fetch byond.com via world_safe_http_get() (rustg async)")

/datum/unit_test/login_findjoindate_no_world_export/Run()
	var/source = read_source_file("code/modules/client/client_procs.dm")
	TEST_ASSERT(length(source) > 1000, "client_procs.dm must be readable (got [length(source)] chars)")

	var/body = _extract_proc_body(source, "/client/proc/findJoinDate()")
	TEST_ASSERT_NOTNULL(body, "/client/proc/findJoinDate() must exist in client_procs.dm")

	// findJoinDate runs synchronously inside set_client_age_from_db (its return value
	// feeds the INSERT), so it cannot be waitfor=FALSE — but it CAN sleep. rustg async
	// makes it sleep-only: the connecting client waits, the world does not.
	TEST_ASSERT(!findtext(body, "world.Export("), "/client/proc/findJoinDate must not call world.Export() — a slow byond.com at roundstart froze the whole world for 10+ seconds")
	TEST_ASSERT(findtext(body, "world_safe_http_get("), "/client/proc/findJoinDate must fetch byond.com via world_safe_http_get() (rustg async)")

/datum/unit_test/ipintel_no_world_export/Run()
	var/source = read_source_file("code/modules/admin/ipintel.dm")
	TEST_ASSERT(length(source) > 500, "ipintel.dm must be readable (got [length(source)] chars)")

	var/body = _extract_proc_body(source, "/proc/ip_intel_query(", "\n/proc/")
	TEST_ASSERT_NOTNULL(body, "/proc/ip_intel_query must exist in ipintel.dm")

	TEST_ASSERT(!findtext(body, "world.Export("), "/proc/ip_intel_query must not call world.Export() — it runs on the client login path")
	TEST_ASSERT(findtext(body, "world_safe_http_get("), "/proc/ip_intel_query must query ipintel via world_safe_http_get() (rustg async)")

/datum/unit_test/redbot_no_world_export/Run()
	var/source = read_source_file("modular_splurt/code/controllers/subsystem/redbot.dm")
	TEST_ASSERT(length(source) > 200, "redbot.dm must be readable (got [length(source)] chars)")

	// Both the roundstart serverStart notification and send_discord_message are
	// fire-and-forget GETs; a dead bot_ip must not stall init or the caller's tick.
	TEST_ASSERT(!findtext(source, "world.Export("), "SSredbot must not call world.Export() — a dead bot_ip freezes the whole world for the connect timeout")
	TEST_ASSERT(findtext(source, "world_safe_http_get"), "SSredbot must send its notifications via world_safe_http_get* (rustg async)")

/datum/unit_test/roundstart_ping_volley_is_single_message/Run()
	var/source = read_source_file("code/controllers/subsystem/ticker.dm")
	TEST_ASSERT(length(source) > 1000, "ticker.dm must be readable (got [length(source)] chars)")

	var/body = _extract_proc_body(source, "/datum/controller/subsystem/ticker/proc/PostSetup()", "\n/datum/controller/subsystem/ticker/proc/")
	TEST_ASSERT_NOTNULL(body, "PostSetup() must exist in ticker.dm")

	// Every send2chat is still a synchronous-to-the-caller TGS bridge round-trip. The
	// rust-g handler keeps the world ticking, but batching avoids needless sleeps and
	// load at the exact moment of roundstart. Role pings must go out as ONE message.
	var/send_count = _count_occurrences(body, "send2chat(")
	TEST_ASSERT(send_count <= 1, "PostSetup must send at most one send2chat message — each call is a synchronous TGS bridge round-trip at roundstart (found [send_count])")

/// TGS must not fall back to its bundled world.Export HTTP handler.
/datum/unit_test/tgs_bridge_uses_rustg_http_handler/Run()
	var/world_source = read_source_file("code/game/world.dm")
	TEST_ASSERT(length(world_source) > 1000, "world.dm must be readable (got [length(world_source)] chars)")
	var/init_body = _extract_proc_body(world_source, "/world/proc/InitTgs()", "\n/world/proc/")
	TEST_ASSERT_NOTNULL(init_body, "/world/proc/InitTgs must exist in world.dm")
	TEST_ASSERT(findtext(init_body, "new /datum/tgs_http_handler/rustg"), "InitTgs must select the sleeping rust-g HTTP handler")

	var/http_source = read_source_file("code/datums/http.dm")
	TEST_ASSERT(findtext(http_source, "/datum/tgs_http_handler/rustg/PerformGet"), "The rust-g TGS HTTP handler must exist")
	TEST_ASSERT(findtext(http_source, "world_safe_http_get(url, TGS_HTTP_TIMEOUT)"), "The TGS handler must use bounded async rust-g HTTP")

/// Response-less HTTP must use rust-g's no-job API, not a detached polling loop.
/datum/unit_test/http_fire_and_forget_creates_no_pollable_job/Run()
	var/http_source = read_source_file("code/datums/http.dm")
	TEST_ASSERT(length(http_source) > 1000, "http.dm must be readable (got [length(http_source)] chars)")
	var/body = _extract_proc_body(http_source, "/proc/world_safe_http_get_async(", "\n/proc/")
	TEST_ASSERT_NOTNULL(body, "/proc/world_safe_http_get_async must exist in http.dm")
	TEST_ASSERT(findtext(body, "request.fire_and_forget()"), "Fire-and-forget GET must use rust-g's no-job request API")
	TEST_ASSERT(!findtext(body, "is_complete()"), "Fire-and-forget GET must not create and poll a native job")

/// All application HTTP integrations use the bounded shared executor.
/datum/unit_test/http_integrations_have_native_and_dm_timeouts/Run()
	var/list/source_paths = list(
		"code/modules/admin/topic.dm",
		"code/modules/mapping/mapping_helpers/_mapping_helpers.dm",
		"modular_bluemoon/code/modules/plug13_integration/plug13.dm",
		"modular_bluemoon/code/controllers/subsystem/cdn_probe.dm",
	)
	for(var/source_path in source_paths)
		var/source = read_source_file(source_path)
		TEST_ASSERT(length(source) > 200, "[source_path] must be readable (got [length(source)] chars)")
		TEST_ASSERT(!findtext(source, ".begin_async()"), "[source_path] bypasses the bounded HTTP executor")
		TEST_ASSERT(findtext(source, "world_safe_http_request(") || findtext(source, "world_safe_http_get("), "[source_path] must use the bounded HTTP executor")

/// HTTP is rust-g-only; the remaining world.Export transport is a measured BYOND Topic call.
/datum/unit_test/world_export_is_limited_to_tracked_byond_topics/Run()
	var/list/topic_source_paths = list(
		"code/modules/client/verbs/autobunker.dm",
		"code/modules/admin/verbs/adminhelp.dm",
	)
	for(var/source_path in topic_source_paths)
		var/source = read_source_file(source_path)
		TEST_ASSERT(length(source) > 200, "[source_path] must be readable (got [length(source)] chars)")
		TEST_ASSERT(!findtext(source, "world.Export("), "[source_path] must not bypass the tracked BYOND Topic request helper")
		TEST_ASSERT(findtext(source, "tracked_byond_topic_request("), "[source_path] must use the shared JSON BYOND Topic request helper")

	var/wrapper_source = read_source_file("modular_bluemoon/code/_HELPERS/blocking_calls.dm")
	TEST_ASSERT(findtext(wrapper_source, ". = world.Export(url)"), "The measured BYOND Topic wrapper must preserve world.Export's return value")
	TEST_ASSERT(findtext(wrapper_source, "use world_safe_http_request() instead"), "The BYOND Topic wrapper must reject accidental HTTP use")

/// Skin round-trips must remain visible to tick-spike instrumentation.
/datum/unit_test/skin_round_trips_use_tracked_wrappers/Run()
	var/list/source_paths = list(
		"code/datums/browser.dm",
		"code/modules/tgui/tgui_window.dm",
		"code/modules/client/client_procs.dm",
	)
	for(var/source_path in source_paths)
		var/source = read_source_file(source_path)
		TEST_ASSERT(length(source) > 1000, "[source_path] must be readable (got [length(source)] chars)")
		var/raw_winexists_count = _count_occurrences(source, "winexists(") - _count_occurrences(source, "tracked_winexists(")
		var/raw_winget_count = _count_occurrences(source, "winget(") - _count_occurrences(source, "tracked_winget(")
		TEST_ASSERT_EQUAL(raw_winexists_count, 0, "[source_path] contains an untracked winexists call")
		TEST_ASSERT_EQUAL(raw_winget_count, 0, "[source_path] contains an untracked winget call")

/// Cosmetic skin checks must not queue behind a client that is still downloading resources.
/datum/unit_test/asset_cache_skin_check_waits_for_responsive_client/Run()
	var/client_source = read_source_file("code/modules/client/client_procs.dm")
	var/body = _extract_proc_body(client_source, "/client/proc/warn_if_no_asset_cache_browser(", "\n/client/proc/")
	TEST_ASSERT_NOTNULL(body, "warn_if_no_asset_cache_browser() must exist")
	TEST_ASSERT(findtext(body, "client_skin_responsive(src)"), "The optional asset-cache winexists call must wait for a responsive client")
	TEST_ASSERT(findtext(body, "tracked_winexists(src, \"asset_cache_browser\")"), "The asset-cache skin check must remain instrumented")

/// Login DPI and automatic macro setup are cosmetic native IPC. Neither may enter a
/// blocking winget before the ping channel proves DreamSeeker responsive.
/datum/unit_test/login_cosmetic_skin_work_waits_for_ping/Run()
	var/client_source = read_source_file("code/modules/client/client_procs.dm")
	var/client_new = _extract_proc_body(client_source, "/client/New(TopicData)", "\n/client/")
	TEST_ASSERT_NOTNULL(client_new, "/client/New must exist")
	TEST_ASSERT(!findtext(client_new, "\n\tacquire_dpi()"), "/client/New must not call blocking DPI winget directly")
	TEST_ASSERT(findtext(client_new, "acquire_dpi_when_ready"), "/client/New must schedule responsive-only DPI acquisition")

	var/dpi_body = _extract_proc_body(client_source, "/client/proc/acquire_dpi_when_ready(", "\n/client/proc/")
	TEST_ASSERT_NOTNULL(dpi_body, "acquire_dpi_when_ready() must exist")
	TEST_ASSERT(findtext(dpi_body, "dpi_telemetry_received"), "login DPI must prefer browser telemetry over winget")
	TEST_ASSERT(findtext(dpi_body, "telemetry_grace_left > 0"), "login DPI must give browser telemetry a bounded response window")
	TEST_ASSERT(findtext(dpi_body, "client_skin_responsive(src)"), "login DPI must wait for a cheap native ping")
	TEST_ASSERT(findtext(dpi_body, "retries_left <= 0"), "login DPI must eventually run for a permanently high-latency client")

	var/keybinding_source = read_source_file("code/modules/keybindings/setup.dm")
	var/macro_body = _extract_proc_body(keybinding_source, "/client/proc/do_full_macro_assert(", "\n/client/proc/")
	TEST_ASSERT_NOTNULL(macro_body, "do_full_macro_assert() must exist")
	TEST_ASSERT(findtext(macro_body, "client_skin_responsive(src)"), "automatic macro setup must wait for a cheap native ping")
	TEST_ASSERT(findtext(macro_body, "macro_assert_busy_retries > 0"), "automatic macro setup must have a bounded fallback")

/// Both kinds of built-in tgui control are known without querying the client skin.
/datum/unit_test/tgui_known_controls_skip_initial_winexists/Run()
	var/panel_source = read_source_file("code/modules/tgui_panel/tgui_panel.dm")
	TEST_ASSERT(findtext(panel_source, "tgui_window_control_types\[\"browseroutput\"\] = \"BROWSER\""), "the fixed chat browser control must be seeded")
	TEST_ASSERT(findtext(panel_source, "client?.browse_queue_flush()"), "the chat panel must flush newly-sent secondary assets")

	var/subsystem_source = read_source_file("code/controllers/subsystem/tgui.dm")
	TEST_ASSERT(findtext(subsystem_source, "tgui_window_control_types\[window_id\] = \"WINDOW\""), "pooled browse windows must be seeded without winexists")

	var/window_source = read_source_file("code/modules/tgui/tgui_window.dm")
	var/initialize_body = _extract_proc_body(window_source, "/datum/tgui_window/proc/initialize(", "\n/datum/tgui_window/proc/")
	TEST_ASSERT_NOTNULL(initialize_body, "tgui_window.initialize() must exist")
	var/send_position = findtext(initialize_body, "flush_queue |= asset.send(client)")
	var/flush_position = findtext(initialize_body, "client.browse_queue_flush()")
	var/browse_position = findtext(initialize_body, "client << browse(html")
	var/type_position = findtext(initialize_body, "var/win_type = client.tgui_window_control_types\[id\]")
	TEST_ASSERT(send_position && flush_position > send_position, "new inline assets must be flushed after browse_rsc sends")
	TEST_ASSERT(browse_position > flush_position, "inline assets must be acknowledged before their HTML page opens")
	TEST_ASSERT(type_position && type_position < flush_position, "known control type must be resolved before asset acknowledgement can deliver an early browser message")
	TEST_ASSERT(!findtext(initialize_body, "winset(client, id, \"is-visible=0\")"), "initialize() must not winset a pooled control before browse() creates it")

	var/message_body = _extract_proc_body(window_source, "/datum/tgui_window/proc/on_message(", "\n/datum/tgui_window/proc/")
	TEST_ASSERT_NOTNULL(message_body, "tgui_window.on_message() must exist")
	TEST_ASSERT(findtext(message_body, "tgui_window_control_types\[id\] == \"WINDOW\""), "the close handler must be restricted to a positively identified native WINDOW")
	TEST_ASSERT(findtext(message_body, "winset(client, id, \"on-close="), "the native close handler must be configured only after the browser proves the control exists")

/// An empty production world must keep ticking when its config explicitly asks
/// it to finish deferred initialization before the first player arrives.
/datum/unit_test/resume_after_initializations_applies_before_sleep/Run()
	var/master_source = read_source_file("code/controllers/master.dm")
	var/sleep_assignment = findtext(master_source, "world.sleep_offline = !CONFIG_GET(flag/resume_after_initializations)")
	var/yield_position = findtext(master_source, "\n\tsleep(1)", sleep_assignment)
	TEST_ASSERT(sleep_assignment, "Master must derive sleep_offline from RESUME_AFTER_INITIALIZATIONS")
	TEST_ASSERT(yield_position > sleep_assignment, "RESUME_AFTER_INITIALIZATIONS must be applied before Master yields to an empty world")

/// Dynamic menu display names are winset parameter values and must be URL encoded.
/datum/unit_test/menu_display_names_are_winset_safe/Run()
	var/verbs_source = read_source_file("code/datums/verbs.dm")
	TEST_ASSERT(length(verbs_source) > 1000, "verbs.dm must be readable")
	TEST_ASSERT(!findtext(verbs_source, "name=\[childname\]"), "Menu child names must not be interpolated raw into winset parameters")
	TEST_ASSERT(findtext(verbs_source, "\"name\" = \"\[childname\]\""), "Menu child names must be encoded through list2params")

/// The custom statbrowser has no native `stat` control; legacy Stat output makes
/// DreamSeeker emit "Element stat not found" and never reaches the HTML panel.
/datum/unit_test/statbrowser_sources_have_no_legacy_stat_output/Run()
	var/list/source_paths = list(
		"modular_bluemoon/code/modules/clothing/nanosuit/nanosuit.dm",
		"modular_bluemoon/code/modules/mob/terror_spiders/terror_spiders.dm",
		"modular_bluemoon/code/modules/mob/terror_spiders/guardian.dm",
		"code/modules/antagonists/clockcult/clock_mobs/clockwork_guardian.dm",
		"code/modules/mob/living/silicon/ai/freelook/cameranet.dm",
	)
	for(var/source_path in source_paths)
		var/source = read_source_file(source_path)
		TEST_ASSERT(length(source) > 500, "[source_path] must be readable")
		TEST_ASSERT(!findtext(source, "statpanel("), "[source_path] still writes to the removed native stat panel")
		TEST_ASSERT(!findtext(source, "/Stat()"), "[source_path] still overrides legacy mob.Stat()")
		TEST_ASSERT(!findtext(source, "\tstat("), "[source_path] still emits legacy stat() rows")

	var/human_source = read_source_file("code/modules/mob/living/carbon/human/human.dm")
	TEST_ASSERT(findtext(human_source, "Crynet Protocols:"), "Nanosuit status must be exposed through the HTML statbrowser")
	for(var/status_source_path in source_paths.Copy(2, 5))
		var/status_source = read_source_file(status_source_path)
		TEST_ASSERT(findtext(status_source, "get_status_tab_items()"), "[status_source_path] must expose data through the HTML statbrowser")

	var/theme_source = read_source_file("tgui/packages/tgui-panel/themes.js")
	TEST_ASSERT(length(theme_source) > 1000, "tgui-panel theme source must be readable")
	TEST_ASSERT(!findtext(theme_source, "'stat."), "tgui-panel themes still winset properties on the removed native stat element")
