/*!
 * Copyright (c) 2020 Aleksej Komarov
 * SPDX-License-Identifier: MIT
 */

/**
 * tgui_panel datum
 * Hosts tgchat and other nice features.
 */
/datum/tgui_panel
	var/client/client
	var/datum/tgui_window/window
	var/broken = FALSE
	var/initialized_at
	/// TRUE once the panel itself reported "ready". The underlying window marks
	/// itself ready on the first message of any kind, which tgui.html sends on
	/// DOMContentLoaded - before the chat bundle has loaded. Legacy output has
	/// to keep running until this flag is set, or everything said in that gap is
	/// lost in both channels.
	var/handshake_done = FALSE

/datum/tgui_panel/New(client/client)
	src.client = client
	// browseroutput is a fixed BROWSER element in interface/skin.dmf. Asking the
	// just-connected skin to rediscover that fact cost up to 2.6 seconds and delayed
	// the panel itself; seed the per-session cache before initialize().
	client.tgui_window_control_types["browseroutput"] = "BROWSER"
	window = new(client, "browseroutput")
	window.subscribe(src, PROC_REF(on_message))

/datum/tgui_panel/Del()
	window.unsubscribe(src)
	window.close()
	return ..()

/**
 * public
 *
 * TRUE if panel is initialized and ready to receive messages.
 */
/datum/tgui_panel/proc/is_ready()
	return !broken && window && !window.fatally_errored && window.is_ready()

/// Sends the complete client/window config. Kept as one message so late DPI telemetry
/// can refresh scale without replacing the nested window config with a partial object.
/datum/tgui_panel/proc/send_client_config()
	window.send_message("update", list(
		"config" = list(
			"client" = list(
				"ckey" = client.ckey,
				"address" = client.address,
				"computer_id" = client.computer_id,
			),
			"window" = list(
				"fancy" = FALSE,
				"locked" = FALSE,
				"scale" = client.get_window_scaling(),
			),
		),
	))

/**
 * public
 *
 * Initializes tgui panel.
 */
/datum/tgui_panel/proc/initialize(force = FALSE)
	set waitfor = FALSE
	// Minimal sleep to defer initialization to after client constructor
	sleep(1)
	initialized_at = world.time
	broken = FALSE
	handshake_done = FALSE
	client?.ensure_resource_session().invalidate_tgui(force ? "tgui panel forced reload" : "tgui panel initialize")
	// Perform a clean initialization
	window.initialize(assets = list(
		get_asset_datum(/datum/asset/simple/tgui_panel),
	))
	var/flush_queue = window.send_asset(get_asset_datum(/datum/asset/simple/namespaced/fontawesome))
	flush_queue |= window.send_asset(get_asset_datum(/datum/asset/simple/namespaced/tgfont))
	flush_queue |= window.send_asset(get_asset_datum(/datum/asset/spritesheet_batched/chat))
	if(flush_queue)
		client?.browse_queue_flush()
	if(!client)
		return
	// Other setup
	request_telemetry()
	addtimer(CALLBACK(src, PROC_REF(on_initialize_timed_out)), 5 SECONDS)

/**
 * private
 *
 * Called when initialization has timed out.
 */
/datum/tgui_panel/proc/on_initialize_timed_out()
	if(is_ready() || broken)
		return
	if(!client)
		return
	// A slow panel is still allowed to finish its handshake. Keep feeding its
	// message queue while legacy output is visible so a late ready message can
	// switch back without losing everything said after this timeout.
	winset(client, "legacy_output_selector", "left=output_legacy")
	SEND_TEXT(client, "<span class=\"userdanger\">Failed to load fancy chat, click <a href='?src=[REF(src)];reload_tguipanel=1'>HERE</a> to attempt to reload it.</span>")

/**
 * private
 *
 * Callback for handling incoming tgui messages.
 */
/datum/tgui_panel/proc/on_message(type, payload, href_list)
	if(type == "log" && href_list?["fatal"])
		broken = TRUE
		client?.ensure_resource_session().invalidate_tgui("fatal tgui panel error", failed = TRUE)
		winset(client, "legacy_output_selector", "left=output_legacy")
		SEND_TEXT(client, "<span class=\"userdanger\">Fancy chat failed and was switched to the legacy output. Use Fix chat to retry.</span>")
		return TRUE
	if(type == "ready")
		broken = FALSE
		handshake_done = TRUE
		client?.ensure_resource_session().note_tgui_ready("tgui ready handshake")
		// Switch to new UI now that the panel is actually loaded.
		// Respects the user's explicit choice to use legacy chat.
		if(!client.use_legacy_chat)
			winset(client, "legacy_output_selector", "left=output_browser")
		send_client_config()
		var/theme = "default"
		if(client?.prefs?.tgui_panel_theme in list("default", "light", "dark"))
			theme = client.prefs.tgui_panel_theme
		window.send_message("panel/theme", list(
			"theme" = theme,
		))
		// Restore saved panel state (chat tabs, filters, settings)
		if(client?.prefs?.tgui_panel_state && length(client.prefs.tgui_panel_state) > 2)
			window.send_message("panel/state", list(
				"state" = client.prefs.tgui_panel_state,
			))
		return TRUE
	if(type == "panel/state_set")
		// State JSON is sent as a direct href parameter (not inside payload)
		// to avoid double-JSON-encoding that inflates the topic URL size.
		var/state_json = href_list?["panel_state"]
		// Fallback: legacy payload path for backward compatibility
		if(!state_json && islist(payload))
			state_json = payload["state"]
		if(!istext(state_json) || length(state_json) > 16384)
			if(client && istext(state_json))
				window.send_message("panel/state_error", list("reason" = "too_large", "size" = length(state_json)))
			return TRUE
		if(client?.prefs && client.prefs.tgui_panel_state != state_json)
			client.prefs.tgui_panel_state = state_json
			client.prefs.save_preferences(bypass_cooldown = TRUE, silent = TRUE)
		return TRUE
	if(type == "panel/theme_set")
		var/theme
		if(islist(payload))
			theme = payload["theme"]
		if(!istext(theme) && islist(href_list))
			theme = href_list["theme"]
		if(theme in list("default", "light", "dark"))
			if(client?.prefs && client.prefs.tgui_panel_theme != theme)
				client.prefs.tgui_panel_theme = theme
				client.prefs.save_preferences(bypass_cooldown = TRUE, silent = TRUE)
		return TRUE
	if(type == "pingDiagnostic")
		if(islist(payload))
			client?.record_browser_latency(
				"tgui_bridge",
				payload["latencyMs"],
				payload["hidden"],
				payload["focused"],
			)
		return TRUE
	if(type == "audio/setAdminMusicVolume")
		client.admin_music_volume = payload["volume"]
		return TRUE
	if(type == "telemetry")
		analyze_telemetry(payload)
		return TRUE

/**
 * public
 *
 * Sends a round restart notification.
 */
/datum/tgui_panel/proc/send_roundrestart()
	window.send_message("roundrestart")
	client?.ensure_resource_session().invalidate_browser("round restart")
