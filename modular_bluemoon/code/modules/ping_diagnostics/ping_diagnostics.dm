/// Number of top subsystems (by tick_usage) shown in the attribution table.
#define PING_SS_TABLE_COUNT 6

/// Per-opener diagnostics panel. Held on client.ping_diag. Players see their own
/// client; admins may target any connected client via the picker.
/datum/ping_diagnostics
	/// The client that opened this panel.
	var/client/owner
	/// Admin-selected target ckey. Null means "diagnose the owner".
	var/target_ckey

/datum/ping_diagnostics/New(client/owner)
	src.owner = owner

/datum/ping_diagnostics/Destroy()
	owner = null
	return ..()

/datum/ping_diagnostics/ui_state(mob/user)
	return GLOB.always_state

/datum/ping_diagnostics/ui_status(mob/user, datum/ui_state/state)
	return UI_INTERACTIVE

/datum/ping_diagnostics/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "PingDiagnostics", "Диагностика пинга")
		ui.open()
		ui.set_autoupdate(TRUE)

/// Resolve which client this panel is currently diagnosing.
/datum/ping_diagnostics/proc/get_target(mob/user)
	var/is_admin = check_rights_for(user?.client, R_ADMIN)
	if(is_admin && target_ckey)
		for(var/client/candidate as anything in GLOB.clients)
			if(candidate.ckey == target_ckey)
				return candidate
	return user?.client

/datum/ping_diagnostics/ui_data(mob/user)
	var/list/data = list()
	var/is_admin = check_rights_for(user?.client, R_ADMIN)
	data["is_admin"] = is_admin

	var/client/target = get_target(user)
	if(!target)
		data["verdict"] = "client"
		data["client_fps"] = 0
		return data

	var/rtt = round(target.avgping_rtt_raw || target.avgping_rtt || target.avgping || 0, 0.1)
	var/server = round(target.avgping_server || 0, 0.1)
	var/jitter = round(target.avgping_jitter || 0, 0.1)
	var/tick = round(target.avgping_tick || 0, 0.1)
	var/client_fps = target.fps || world.fps
	var/floor = estimate_ping_floor(client_fps)
	var/time_dilation = round(SStime_track.time_dilation_current, 0.1)
	var/rtt_max = round(target.lastping_rtt_max || 0, 0.1)
	var/spike = max(rtt_max - rtt, 0)

	data["target_key"] = target.key
	data["rtt"] = rtt
	data["server"] = server
	data["jitter"] = jitter
	data["tick"] = tick
	data["floor"] = floor
	data["total"] = round(rtt + server, 0.1)
	data["client_fps"] = client_fps
	data["tidi"] = time_dilation
	data["rtt_max"] = rtt_max
	data["spike"] = round(spike, 0.1)
	data["history"] = target.ping_history?.Copy() || list()

	var/verdict = classify_ping(rtt, server, jitter, floor, client_fps, time_dilation, spike)
	data["verdict"] = verdict

	// Server-wide ping list, shown to everyone: each connected client's key and average
	// ping, so any player can see how the whole server feels, not just their own number.
	// own_key marks the viewer's row so they can find themselves in the list. Stealth admins
	// show their fakekey to non-admin viewers, mirroring the /who verb so the panel can't be
	// used to deanonymize them; admins still see the real keys.
	data["own_key"] = user?.client?.key
	var/list/all_pings = list()
	for(var/client/candidate as anything in GLOB.clients)
		var/display_key = candidate.key
		if(!is_admin && candidate.holder?.fakekey)
			display_key = candidate.holder.fakekey
		all_pings += list(list(
			"key" = display_key,
			"ping" = round(candidate.avgping, 1),
		))
	data["all_pings"] = all_pings

	// Subsystem attribution: included for admins, or for any viewer when the server is
	// the culprit, so a player can see what is eating the tick.
	if(is_admin || verdict == PING_VERDICT_SERVER)
		// Rank firing subsystems by tick_usage and send only the rows the table shows.
		// This panel autoupdates during lag moments, so we keep the per-refresh payload
		// small instead of shipping all ~50 subsystems for the client to sort and slice.
		var/list/firing = list()
		for(var/datum/controller/subsystem/SS as anything in Master.subsystems)
			if(SS.flags & SS_NO_FIRE)
				continue
			firing[SS] = SS.tick_usage
		sortTim(firing, GLOBAL_PROC_REF(cmp_numeric_dsc), associative = TRUE)
		var/list/ss_costs = list()
		for(var/datum/controller/subsystem/SS as anything in firing)
			if(ss_costs.len >= PING_SS_TABLE_COUNT)
				break
			ss_costs += list(list(
				"name" = SS.name,
				"cost" = round(SS.cost, 0.1),
				"tick_usage" = round(SS.tick_usage, 0.1),
			))
		data["ss_costs"] = ss_costs
		data["ss_count"] = PING_SS_TABLE_COUNT
		data["maptick"] = round(MAPTICK_LAST_INTERNAL_TICK_USAGE, 0.1)

	// Admin-only client picker list.
	if(is_admin)
		var/list/clients = list()
		for(var/client/candidate as anything in GLOB.clients)
			clients += list(list(
				"key" = candidate.key,
				"ckey" = candidate.ckey,
				"ping" = round(candidate.avgping, 1),
			))
		data["clients"] = clients

	return data

/datum/ping_diagnostics/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	if(.)
		return
	switch(action)
		if("select_target")
			if(!check_rights_for(ui.user?.client, R_ADMIN))
				return
			target_ckey = params["ckey"]
			return TRUE
		if("reset_target")
			if(!check_rights_for(ui.user?.client, R_ADMIN))
				return
			target_ckey = null
			return TRUE

/client/verb/ping_diagnostics()
	set name = "Ping Diagnostics"
	set category = "OOC"
	if(!ping_diag)
		ping_diag = new(src)
	ping_diag.ui_interact(mob)

#undef PING_SS_TABLE_COUNT
