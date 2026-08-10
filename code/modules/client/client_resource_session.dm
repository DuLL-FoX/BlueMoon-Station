/**
 * Per-connection lifecycle for native and browser resources.
 *
 * A new /client gets a new generation and nonce. Delayed callbacks may pass the generation
 * they were created for, preventing a stale browser/window callback from reviving a newer
 * lifecycle. Capabilities are deliberately independent: losing fancy chat must not make a
 * working statbrowser or already delivered RSC look unavailable.
 */
/datum/client_resource_session
	var/static/next_generation = 0
	var/client/client
	var/generation
	var/nonce
	var/created_at
	var/list/capability_states
	var/list/capability_changed_at
	var/list/capability_reasons

/datum/client_resource_session/New(client/owner)
	client = owner
	generation = ++next_generation
	created_at = REALTIMEOFDAY
	nonce = md5("[created_at]-[world.time]-[generation]-[rand(1, 1e9)]")
	capability_states = list(
		CLIENT_CAPABILITY_RSC = CLIENT_CAPABILITY_PENDING,
		CLIENT_CAPABILITY_ASSET_CACHE = CLIENT_CAPABILITY_PENDING,
		CLIENT_CAPABILITY_STATBROWSER = CLIENT_CAPABILITY_PENDING,
		CLIENT_CAPABILITY_TGUI_PANEL = CLIENT_CAPABILITY_PENDING,
		CLIENT_CAPABILITY_SKIN = CLIENT_CAPABILITY_PENDING,
		CLIENT_CAPABILITY_BROWSER = CLIENT_CAPABILITY_PENDING,
	)
	capability_changed_at = list()
	capability_reasons = list()
	for(var/capability in capability_states)
		capability_changed_at[capability] = created_at

/datum/client_resource_session/Destroy()
	client = null
	capability_states = null
	capability_changed_at = null
	capability_reasons = null
	return ..()

/// Updates one capability. expected_generation rejects callbacks from an older lifecycle.
/datum/client_resource_session/proc/set_capability(capability, state, reason, expected_generation)
	if(!isnull(expected_generation) && expected_generation != generation)
		return FALSE
	if(!(capability in capability_states))
		return FALSE
	switch(state)
		if(CLIENT_CAPABILITY_PENDING, CLIENT_CAPABILITY_REQUESTED, CLIENT_CAPABILITY_READY, CLIENT_CAPABILITY_DEGRADED, CLIENT_CAPABILITY_FAILED, CLIENT_CAPABILITY_INVALIDATED)
			// Valid state.
		else
			return FALSE
	if(capability_states[capability] == state && capability_reasons[capability] == reason)
		return TRUE
	capability_states[capability] = state
	capability_changed_at[capability] = REALTIMEOFDAY
	if(reason)
		capability_reasons[capability] = "[reason]"
	else
		capability_reasons -= capability
	return TRUE

/datum/client_resource_session/proc/get_capability(capability)
	return capability_states[capability]

/datum/client_resource_session/proc/is_capability_ready(capability, allow_degraded = FALSE)
	var/state = capability_states[capability]
	return state == CLIENT_CAPABILITY_READY || (allow_degraded && state == CLIENT_CAPABILITY_DEGRADED)

/// Derives overall browser health without collapsing the independent window states.
/datum/client_resource_session/proc/refresh_browser_health(reason)
	var/statbrowser_state = capability_states[CLIENT_CAPABILITY_STATBROWSER]
	var/tgui_state = capability_states[CLIENT_CAPABILITY_TGUI_PANEL]
	// Keep each comparison explicit. In DM, `in` has lower precedence than boolean
	// operators, so combining two `state in list(...)` expressions without extra
	// grouping can evaluate the right-hand list as part of the first membership test.
	var/statbrowser_is_degraded = statbrowser_state == CLIENT_CAPABILITY_FAILED || statbrowser_state == CLIENT_CAPABILITY_DEGRADED
	var/tgui_is_degraded = tgui_state == CLIENT_CAPABILITY_FAILED || tgui_state == CLIENT_CAPABILITY_DEGRADED
	if(statbrowser_is_degraded || tgui_is_degraded)
		return set_capability(CLIENT_CAPABILITY_BROWSER, CLIENT_CAPABILITY_DEGRADED, reason)
	if(statbrowser_state == CLIENT_CAPABILITY_READY || tgui_state == CLIENT_CAPABILITY_READY)
		return set_capability(CLIENT_CAPABILITY_BROWSER, CLIENT_CAPABILITY_READY, reason)
	if(statbrowser_state == CLIENT_CAPABILITY_INVALIDATED && tgui_state == CLIENT_CAPABILITY_INVALIDATED)
		return set_capability(CLIENT_CAPABILITY_BROWSER, CLIENT_CAPABILITY_INVALIDATED, reason)
	return set_capability(CLIENT_CAPABILITY_BROWSER, CLIENT_CAPABILITY_PENDING, reason)

/// Compatibility projection for the existing resource-stage metrics.
/datum/client_resource_session/proc/advance_legacy_stage(stage)
	if(!client || stage <= client.resource_stage)
		return
	client.resource_stage = stage
	// Text keys are required: BYOND interprets numeric keys as list indices.
	client.resource_stage_times["[stage]"] = REALTIMEOFDAY

/datum/client_resource_session/proc/note_rsc_requested(reason)
	set_capability(CLIENT_CAPABILITY_RSC, CLIENT_CAPABILITY_REQUESTED, reason)
	advance_legacy_stage(CLIENT_RESOURCE_STAGE_REQUESTED)

/datum/client_resource_session/proc/note_asset_cache_ready(reason)
	set_capability(CLIENT_CAPABILITY_ASSET_CACHE, CLIENT_CAPABILITY_READY, reason)
	advance_legacy_stage(CLIENT_RESOURCE_STAGE_ASSETS_ACK)

/datum/client_resource_session/proc/note_statbrowser_ready(degraded = FALSE, reason)
	set_capability(CLIENT_CAPABILITY_STATBROWSER, degraded ? CLIENT_CAPABILITY_DEGRADED : CLIENT_CAPABILITY_READY, reason)
	refresh_browser_health(reason)
	if(client)
		client.statbrowser_ready = TRUE
	if(!degraded)
		advance_legacy_stage(CLIENT_RESOURCE_STAGE_STATBROWSER)

/datum/client_resource_session/proc/invalidate_statbrowser(reason)
	set_capability(CLIENT_CAPABILITY_STATBROWSER, CLIENT_CAPABILITY_INVALIDATED, reason)
	refresh_browser_health(reason)
	if(client)
		client.statbrowser_ready = FALSE

/datum/client_resource_session/proc/note_tgui_ready(reason)
	set_capability(CLIENT_CAPABILITY_TGUI_PANEL, CLIENT_CAPABILITY_READY, reason)
	refresh_browser_health(reason)

/datum/client_resource_session/proc/invalidate_tgui(reason, failed = FALSE)
	set_capability(CLIENT_CAPABILITY_TGUI_PANEL, failed ? CLIENT_CAPABILITY_FAILED : CLIENT_CAPABILITY_INVALIDATED, reason)
	refresh_browser_health(reason)

/// Invalidates browser windows for round restart or an explicit browser lifecycle reset.
/datum/client_resource_session/proc/invalidate_browser(reason)
	invalidate_statbrowser(reason)
	invalidate_tgui(reason)
	set_capability(CLIENT_CAPABILITY_BROWSER, CLIENT_CAPABILITY_INVALIDATED, reason)

/// Preserves all existing advance_resource_stage() callers while routing them through the session.
/datum/client_resource_session/proc/apply_legacy_stage(stage)
	switch(stage)
		if(CLIENT_RESOURCE_STAGE_REQUESTED)
			set_capability(CLIENT_CAPABILITY_RSC, CLIENT_CAPABILITY_REQUESTED, "legacy stage adapter")
		if(CLIENT_RESOURCE_STAGE_ASSETS_ACK)
			set_capability(CLIENT_CAPABILITY_ASSET_CACHE, CLIENT_CAPABILITY_READY, "legacy stage adapter")
		if(CLIENT_RESOURCE_STAGE_STATBROWSER)
			set_capability(CLIENT_CAPABILITY_STATBROWSER, CLIENT_CAPABILITY_READY, "legacy stage adapter")
			refresh_browser_health("legacy stage adapter")
		if(CLIENT_RESOURCE_STAGE_UI_READY)
			set_capability(CLIENT_CAPABILITY_SKIN, CLIENT_CAPABILITY_READY, "native ping confirmed")
	advance_legacy_stage(stage)

/// JSON-safe snapshot for latency diagnostics. Existing top-level fields remain unchanged.
/datum/client_resource_session/proc/snapshot()
	return list(
		"generation" = generation,
		"nonce" = nonce,
		"release_id" = DEPLOYMENT_RELEASE_ID,
		"created_at" = created_at,
		"states" = capability_states.Copy(),
		"changed_at" = capability_changed_at.Copy(),
		"reasons" = capability_reasons.Copy(),
	)

/datum/client_resource_session/proc/summary()
	var/list/parts = list()
	for(var/capability in capability_states)
		parts += "[capability]=[capability_states[capability]]"
	return "release=[DEPLOYMENT_RELEASE_ID || "unmanaged"] g[generation] [parts.Join(",")]"

/client/proc/ensure_resource_session()
	RETURN_TYPE(/datum/client_resource_session)
	if(!resource_session || QDELETED(resource_session))
		resource_session = new(src)
	return resource_session
