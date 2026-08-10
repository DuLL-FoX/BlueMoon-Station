/*!
 * Copyright (c) 2020 Aleksej Komarov
 * SPDX-License-Identifier: MIT
 */

/**
 * Maximum number of connection records allowed to analyze.
 * Should match the value set in the browser.
 */
#define TGUI_TELEMETRY_MAX_CONNECTIONS 5

/**
 * Maximum time allocated for sending a telemetry packet.
 */
#define TGUI_TELEMETRY_RESPONSE_WINDOW 30 SECONDS

/// Browser telemetry is untrusted. Values outside ordinary OS/browser scaling ranges
/// are ignored rather than being allowed to distort every subsequently opened UI.
#define TGUI_DEVICE_PIXEL_RATIO_MIN 0.5
#define TGUI_DEVICE_PIXEL_RATIO_MAX 4

/// Returns a bounded two-decimal scaling value, or null for an untrusted value.
/proc/sanitize_tgui_device_pixel_ratio(value)
	if(!isnum(value) || value < TGUI_DEVICE_PIXEL_RATIO_MIN || value > TGUI_DEVICE_PIXEL_RATIO_MAX)
		return null
	return round(value, 0.01)

/// Applies browser-reported scaling and lets the pending login fallback become a no-op.
/client/proc/apply_tgui_device_pixel_ratio(value)
	var/sanitized_ratio = sanitize_tgui_device_pixel_ratio(value)
	if(isnull(sanitized_ratio))
		return FALSE
	window_scaling = sanitized_ratio
	window_scaling_retry_count = 0
	dpi_telemetry_received = TRUE
	ensure_resource_session().set_capability(CLIENT_CAPABILITY_SKIN, CLIENT_CAPABILITY_READY, "tgui devicePixelRatio")
	if(tgui_panel?.handshake_done)
		tgui_panel.send_client_config()
	return TRUE

/// Time of telemetry request
/datum/tgui_panel/var/telemetry_requested_at
/// Time of telemetry analysis completion
/datum/tgui_panel/var/telemetry_analyzed_at
/// List of previous client connections
/datum/tgui_panel/var/list/telemetry_connections

/**
 * private
 *
 * Requests some telemetry from the client.
 */
/datum/tgui_panel/proc/request_telemetry()
	telemetry_requested_at = world.time
	telemetry_analyzed_at = null
	window.send_message("telemetry/request", list(
		"limits" = list(
			"connections" = TGUI_TELEMETRY_MAX_CONNECTIONS,
		),
	))

/**
 * private
 *
 * Analyzes a telemetry packet.
 *
 * Is currently only useful for detecting ban evasion attempts.
 */
/datum/tgui_panel/proc/analyze_telemetry(payload)
	if(world.time > telemetry_requested_at + TGUI_TELEMETRY_RESPONSE_WINDOW)
		message_admins("[key_name(client)] sent telemetry outside of the allocated time window.")
		return
	if(telemetry_analyzed_at)
		message_admins("[key_name(client)] sent telemetry more than once.")
		return
	telemetry_analyzed_at = world.time
	if(!islist(payload))
		return
	client?.apply_tgui_device_pixel_ratio(payload["pixelRatio"])
	telemetry_connections = payload["connections"]
	var/len = length(telemetry_connections)
	if(len == 0)
		return
	if(len > TGUI_TELEMETRY_MAX_CONNECTIONS)
		message_admins("[key_name(client)] was kicked for sending a huge telemetry payload")
		qdel(client)
		return
	var/list/found
	for(var/i in 1 to len)
		if(QDELETED(client))
			// He got cleaned up before we were done
			return
		var/list/row = telemetry_connections[i]
		// Check for a malformed history object
		if (!row || row.len < 3 || (!row["ckey"] || !row["address"] || !row["computer_id"]))
			return
		if (world.IsBanned(row["ckey"], row["address"], row["computer_id"], real_bans_only = TRUE))
			found = row
			break
		CHECK_TICK
	// This fucker has a history of playing on a banned account.
	// BLUEMOON EDIT START: Telemetry
	if(found)
		if(!client?.holder?.check_for_rights(R_PERMISSIONS))
			var/msg = "[key_name(client)] has a banned account in connection history! https://iphub.info/?ip=[client.address] (Actual: [client.ckey], [client.address], [client.computer_id] ) (Matched: [found["ckey"]], [found["address"]], [found["computer_id"]])"
			suspect_message_to_admin_chat(msg)
			log_admin_private(msg)
			log_suspicious_login(msg, access_log_mirror = FALSE)
	// BLUEMOON EDIT END: Telemetry

#undef TGUI_DEVICE_PIXEL_RATIO_MIN
#undef TGUI_DEVICE_PIXEL_RATIO_MAX
