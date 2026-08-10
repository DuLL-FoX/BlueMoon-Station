//wrapper macros for easier grepping
#define DIRECT_OUTPUT(A, B) A << B
#define DIRECT_INPUT(A, B) A >> B
#define SEND_IMAGE(target, image) DIRECT_OUTPUT(target, image)
#define SEND_SOUND(target, sound) DIRECT_OUTPUT(target, sound)
#define SEND_TEXT(target, text) DIRECT_OUTPUT(target, text)
#define WRITE_FILE(file, text) DIRECT_OUTPUT(file, text)
#define READ_FILE(file, text) DIRECT_INPUT(file, text)

#ifdef EXTOOLS_LOGGING
// proc hooked, so we can just put in standard TRUE and FALSE
#define WRITE_LOG(log, text) extools_log_write(log,text,TRUE)
#define WRITE_LOG_NO_FORMAT(log, text) extools_log_write(log,text,FALSE)
#else
//This is an external call, "true" and "false" are how rust parses out booleans
#define WRITE_LOG(log, text) rustg_log_write(log, text, "true")
#define WRITE_LOG_NO_FORMAT(log, text) rustg_log_write(log, text, "false")
#endif

//print a warning message to world.log
#define WARNING(MSG) warning("[MSG] in [__FILE__] at line [__LINE__] src: [UNLINT(src)] usr: [usr].")
/proc/warning(msg)
	msg = "## WARNING: [msg]"
	log_world(msg)

//not an error or a warning, but worth to mention on the world log, just in case.
#define NOTICE(MSG) notice(MSG)
/proc/notice(msg)
	msg = "## NOTICE: [msg]"
	log_world(msg)

//print a testing-mode debug message to world.log and world
#ifdef TESTING
#define testing(msg) log_world("## TESTING: [msg]"); to_chat(world, "## TESTING: [msg]")
#else
#define testing(msg)
#endif

#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)
/proc/log_test(text)
	WRITE_LOG(GLOB.test_log, text)
	SEND_TEXT(world.log, text)
#endif

// Лог рефтрекера пишется всегда: файл data/logs/<раунд>/harddels.log создаётся каждый раунд.
#define log_reftracker(msg) log_harddel("## REF SEARCH [msg]")

/proc/log_harddel(text)
	WRITE_LOG(GLOB.harddel_log, text)


/* Items with ADMINPRIVATE prefixed are stripped from public logs. */
/proc/log_admin(text, list/data)
	WRITE_LOG(GLOB.world_game_log, "ADMIN: [text]")
	WRITE_LOG(GLOB.admin_log, "ADMIN: [text]")
	GLOB.admin_log_entries += "ADMIN: [text]"

/proc/log_admin_private(text, list/data)
	WRITE_LOG(GLOB.world_game_log, "ADMINPRIVATE: [text]")
	WRITE_LOG(GLOB.admin_log, "ADMIN: [text]")
	GLOB.admin_log_entries += "ADMIN: [text]"

/proc/log_adminsay(text, list/data)
	WRITE_LOG(GLOB.world_game_log, "ADMINPRIVATE: ASAY: [text]")

/proc/log_dsay(text, list/data)
	WRITE_LOG(GLOB.world_game_log, "ADMIN: DSAY: [text]")

/proc/log_consent(text)
	WRITE_LOG(GLOB.world_game_log, "CONSENT: [text]")

/* All other items are public. */
/proc/log_game(text)
	if (CONFIG_GET(flag/log_game))
		WRITE_LOG(GLOB.world_game_log, "GAME: [text]")

/proc/log_mecha(text)
	if (CONFIG_GET(flag/log_mecha))
		WRITE_LOG(GLOB.world_mecha_log, "MECHA: [text]")

/proc/log_uplink(text)
	if (CONFIG_GET(flag/log_uplink))
		WRITE_LOG(GLOB.uplink_log, "UPLINK: [text]")

/proc/log_virus(text)
	if (CONFIG_GET(flag/log_virus))
		WRITE_LOG(GLOB.world_virus_log, "VIRUS: [text]")

/proc/log_asset(text)
	WRITE_LOG(GLOB.world_asset_log, "ASSET: [text]")

/proc/log_access(text)
	if (CONFIG_GET(flag/log_access))
		WRITE_LOG(GLOB.world_game_log, "ACCESS: [text]")

/**
 * Writes to a special log file if the log_suspicious_login config flag is set,
 * which is intended to contain all logins that failed under suspicious circumstances.
 *
 * Mirrors this log entry to log_access when access_log_mirror is TRUE, so this proc
 * doesn't need to be used alongside log_access and can replace it where appropriate.
 */
/proc/log_suspicious_login(text, access_log_mirror = TRUE)
	if (CONFIG_GET(flag/log_suspicious_login))
		WRITE_LOG(GLOB.world_suspicious_login_log, "SUSPICIOUS_ACCESS: [text]")
	if(access_log_mirror)
		log_access(text)

/proc/log_law(text)
	if (CONFIG_GET(flag/log_law))
		WRITE_LOG(GLOB.world_game_log, "LAW: [text]")

/proc/log_attack(text)
	if (CONFIG_GET(flag/log_attack))
		WRITE_LOG(GLOB.world_attack_log, "ATTACK: [text]")

/proc/log_victim(text)
	if (CONFIG_GET(flag/log_victim))
		WRITE_LOG(GLOB.world_victim_log, "VICTIM: [text]")

/proc/log_manifest(ckey, datum/mind/mind,mob/body, latejoin = FALSE)
	if (CONFIG_GET(flag/log_manifest))
		WRITE_LOG(GLOB.world_manifest_log, "[ckey] \\ [body.real_name] \\ [mind.assigned_role] \\ [mind.special_role ? mind.special_role : "NONE"] \\ [latejoin ? "LATEJOIN":"ROUNDSTART"]")

/proc/log_say(text)
	if (CONFIG_GET(flag/log_say))
		WRITE_LOG(GLOB.world_game_log, "SAY: [text]")

/proc/log_ooc(text)
	if (CONFIG_GET(flag/log_ooc))
		WRITE_LOG(GLOB.world_game_log, "OOC: [text]")

/proc/log_whisper(text)
	if (CONFIG_GET(flag/log_whisper))
		WRITE_LOG(GLOB.world_game_log, "WHISPER: [text]")

/proc/log_emote(text)
	if (CONFIG_GET(flag/log_emote))
		WRITE_LOG(GLOB.world_game_log, "EMOTE: [text]")

/proc/log_subtler(text)
	if (CONFIG_GET(flag/log_emote))
		WRITE_LOG(GLOB.world_game_log, "EMOTE (SUBTLER): [text]")

/proc/log_prayer(text)
	if (CONFIG_GET(flag/log_prayer))
		WRITE_LOG(GLOB.world_game_log, "PRAY: [text]")

/proc/log_pda(text)
	if (CONFIG_GET(flag/log_pda))
		WRITE_LOG(GLOB.world_pda_log, "PDA: [text]")

/proc/log_comment(text)
	if (CONFIG_GET(flag/log_pda))
		//reusing the PDA option because I really don't think news comments are worth a config option
		WRITE_LOG(GLOB.world_pda_log, "COMMENT: [text]")

/proc/log_paper(text)
	WRITE_LOG(GLOB.world_paper_log, "PAPER: [text]")

/proc/log_telecomms(text)
	if (CONFIG_GET(flag/log_telecomms))
		WRITE_LOG(GLOB.world_telecomms_log, "TCOMMS: [text]")

/proc/log_econ(text)
	if (CONFIG_GET(flag/log_econ))
		WRITE_LOG(GLOB.world_econ_log, "MONEY: [text]")

/proc/log_chat(text)
	if (CONFIG_GET(flag/log_pda))
		//same thing here
		WRITE_LOG(GLOB.world_pda_log, "CHAT: [text]")

/proc/log_vote(text)
	if (CONFIG_GET(flag/log_vote))
		WRITE_LOG(GLOB.admin_log, "VOTE: [text]")
		GLOB.admin_log_entries += "VOTE: [text]"

/proc/log_shuttle(text)
	if (CONFIG_GET(flag/log_shuttle))
		WRITE_LOG(GLOB.world_shuttle_log, "SHUTTLE: [text]")

/proc/log_craft(text)
	if (CONFIG_GET(flag/log_craft))
		WRITE_LOG(GLOB.world_crafting_log, "CRAFT: [text]")

/proc/log_topic(text)
	WRITE_LOG(GLOB.world_game_log, "TOPIC: [text]")

/proc/log_href(text)
	WRITE_LOG(GLOB.world_href_log, "HREF: [text]")

/proc/log_sql(text)
	WRITE_LOG(GLOB.sql_error_log, "SQL: [text]")

/proc/log_qdel(text)
	WRITE_LOG(GLOB.world_qdel_log, "QDEL: [text]")

/proc/log_query_debug(text)
	WRITE_LOG(GLOB.query_debug_log, "SQL: [text]")

/proc/log_job_debug(text)
	if (CONFIG_GET(flag/log_job_debug))
		WRITE_LOG(GLOB.world_job_debug_log, "JOB: [text]")

/proc/log_subsystem(subsystem, text)
	WRITE_LOG(GLOB.subsystem_log, "[subsystem]: [text]")

/proc/log_click(atom/object, atom/location, control, params, client/C, event = "clicked", unexpected)
	WRITE_LOG(GLOB.click_log, "[unexpected? "ERROR" :"CLICK"]: [C.ckey] - [event] : [istype(object)? "[object] ([COORD(object)])" : object] | [istype(location)? "[location] ([COORD(location)])" : location] | [control] | [params]")

/* Log to both DD and the logfile. */
/proc/log_world(text)
#ifdef USE_CUSTOM_ERROR_HANDLER
	WRITE_LOG(GLOB.world_runtime_log, text)
#endif
	SEND_TEXT(world.log, text)

/* Log to the logfile only. */
/proc/log_runtime(text)
	WRITE_LOG(GLOB.world_runtime_log, text)

/* Rarely gets called; just here in case the config breaks. */
/proc/log_config(text)
	WRITE_LOG(GLOB.config_error_log, text)
	SEND_TEXT(world.log, text)

/proc/log_mapping(text)
// BLUEMOON EDIT START: Invalid Space Turfs
#ifdef UNIT_TESTS
	GLOB.unit_test_mapping_logs += text
#endif
// BLUEMOON EDIT END: Invalid Space Turfs
	WRITE_LOG(GLOB.world_map_error_log, text)

/proc/log_perf(list/perf_info)
	. = "[perf_info.Join(",")]\n"
	WRITE_LOG_NO_FORMAT(GLOB.perf_log, .)

/proc/log_ping_perf(list/perf_info)
	. = "[perf_info.Join(",")]\n"
	WRITE_LOG_NO_FORMAT(GLOB.ping_perf_log, .)

/**
 * Пишет одно самодостаточное JSONL-событие о клиентской задержке.
 *
 * Файл намеренно отдельный от tick_spikes.log: задержка DreamSeeker обычно не
 * тормозит Master Controller и потому не обязана совпасть с серверным тик-спайком.
 * Общий снимок делает события skin/browser/Topic/native ping сопоставимыми по
 * world_time, ckey и состоянию клиента без дополнительных блокирующих winget.
 */
/proc/log_client_latency(event, client/target, list/details)
	if(!GLOB.client_latency_log)
		return

	var/list/entry = list(
		"event" = "[event]",
		// world.realtime is already large enough to lose roughly 51 seconds per
		// representable float step. Formatting it produced batches of events with
		// the same stale timestamp. rust-g reads the host clock directly and keeps
		// both milliseconds and the local UTC offset.
		"timestamp" = rustg_formatted_timestamp("%Y-%m-%dT%H:%M:%S%.3f%:z"),
		"round_id" = GLOB.round_id,
		"world_time" = world.time,
		"realtime_ds" = REALTIMEOFDAY,
		"server_byond" = "[world.byond_version].[world.byond_build]",
		"world_cpu" = world.cpu,
		"tick_usage" = TICK_USAGE,
		"maptick" = MAPTICK_LAST_INTERNAL_TICK_USAGE,
		"mc_iteration" = Master?.iteration || 0,
		"tidi" = SStime_track?.time_dilation_current || 0,
		"tidi_fast" = SStime_track?.time_dilation_avg_fast || 0,
	)

	if(target)
		var/turf/mob_turf = get_turf(target.mob)
		var/atom/eye_atom = target.eye
		var/turf/eye_turf = get_turf(eye_atom)
		entry["ckey"] = target.ckey || "<none>"
		entry["address"] = target.address
		entry["client_byond"] = "[target.byond_version].[target.byond_build]"
		entry["connection_age_ds"] = target.connection_time ? max(world.time - target.connection_time, 0) : null
		entry["resource_stage"] = client_resource_stage_name(target.resource_stage)
		entry["resource_session"] = target.resource_session?.snapshot()
		entry["rsc_source"] = target.rsc_source_url || CLIENT_RSC_SOURCE_LOCAL
		entry["statbrowser_ready"] = !!target.statbrowser_ready
		entry["statbrowser_served_externally"] = !!target.statbrowser_served_externally
		entry["statbrowser_local_fallback"] = !!target.statbrowser_local_fallback
		entry["tgui_ready"] = !!target.tgui_panel?.is_ready()
		entry["tgui_windows"] = length(target.tgui_windows)
		entry["inactivity_ds"] = target.inactivity
		entry["mob_type"] = target.mob ? "[target.mob.type]" : null
		entry["mob_coord"] = mob_turf ? "[mob_turf.x],[mob_turf.y],[mob_turf.z]" : null
		entry["eye_type"] = eye_atom ? "[eye_atom.type]" : null
		entry["eye_coord"] = eye_turf ? "[eye_turf.x],[eye_turf.y],[eye_turf.z]" : null
		entry["view"] = "[target.view]"
		entry["screen_objects"] = length(target.screen)
		entry["client_images"] = length(target.images)
		entry["last_native_rtt_ms"] = target.lastping_rtt_raw
		entry["last_native_tick_ms"] = target.lastping_tick
		entry["last_native_server_ms"] = target.lastping_server
		entry["last_native_age_ds"] = target.lastping_at ? max(world.time - target.lastping_at, 0) : null
		entry["ping_sequence_sent"] = target.ping_sequence_sent
		entry["ping_sequence_received"] = target.ping_sequence_received

		if(target.last_skin_latency_at)
			entry["recent_skin_age_ds"] = max(world.time - target.last_skin_latency_at, 0)
			entry["recent_skin_kind"] = target.last_skin_latency_kind
			entry["recent_skin_ms"] = target.last_skin_latency_ms
			entry["recent_skin_detail"] = target.last_skin_latency_detail
		if(target.last_slow_topic_at)
			entry["recent_topic_age_ds"] = max(world.time - target.last_slow_topic_at, 0)
			entry["recent_topic_context"] = target.last_slow_topic_context
			entry["recent_topic_ms"] = target.last_slow_topic_ms
		if(target.last_browser_latency_at)
			entry["recent_browser_age_ds"] = max(world.time - target.last_browser_latency_at, 0)
			entry["recent_browser_source"] = target.last_browser_latency_source
			entry["recent_browser_ms"] = target.last_browser_latency_ms
			entry["recent_browser_hidden"] = !!target.last_browser_latency_hidden
			entry["recent_browser_focused"] = !!target.last_browser_latency_focused

	if(islist(details))
		for(var/key in details)
			entry[key] = details[key]

	WRITE_LOG_NO_FORMAT(GLOB.client_latency_log, "[json_encode(entry)]\n")

/// Starts a low-frequency latency profile that can distinguish synchronous work from
/// deliberate CHECK_TICK sleeps. TICK_USAGE cannot be used here because it resets on
/// every server tick.
/proc/client_latency_profile_start()
	if(!SStick_spikes)
		return
	return list(
		"wall_ms" = SStick_spikes.now_ms(),
		"world_time" = world.time,
	)

/// Adds the synchronous part of one phase and advances the checkpoint. World time
/// advances while stoplag() yields, so subtracting its progress prevents a healthy
/// yield from being reported as expensive DM work.
/proc/client_latency_profile_checkpoint(list/phases, label, list/previous)
	if(!SStick_spikes || !islist(previous))
		return previous
	var/current_ms = SStick_spikes.now_ms()
	var/current_world_time = world.time
	var/wall_ms = max(current_ms - previous["wall_ms"], 0)
	var/game_clock_ms = max(current_world_time - previous["world_time"], 0) * 100
	phases[label] = round(ping_server_component(wall_ms, game_clock_ms), 0.01)
	previous["wall_ms"] = current_ms
	previous["world_time"] = current_world_time
	return previous

/proc/log_reagent(text)
	if (CONFIG_GET(flag/log_reagents))
		WRITE_LOG(GLOB.reagent_log, text)

/proc/log_reagent_transfer(text)
	log_reagent("TRANSFER: [text]")

/* For logging round startup. */
/proc/start_log(log)
	WRITE_LOG(log, "Starting up round ID [GLOB.round_id].\n-------------------------")

/**
 * Appends a tgui-related log entry. All arguments are optional.
 */
/proc/log_tgui(user, message, context,
		datum/tgui_window/window,
		datum/src_object)
	var/entry = ""
	// Insert user info
	if(!user)
		entry += "<nobody>"
	else if(istype(user, /mob))
		var/mob/mob = user
		entry += "[mob.ckey] (as [mob] at [mob.x],[mob.y],[mob.z])"
	else if(istype(user, /client))
		var/client/client = user
		entry += "[client.ckey]"
	// Insert context
	if(context)
		entry += " in [context]"
	else if(window)
		entry += " in [window.id]"
	// Resolve src_object
	if(!src_object && window && window.locked_by)
		src_object = window.locked_by.src_object
	// Insert src_object info
	if(src_object)
		entry += "Using: [src_object.type] [REF(src_object)]"
	// Insert message
	if(message)
		entry += "[message]"
	WRITE_LOG(GLOB.tgui_log, entry)

/* Close open log handles. This should be called as late as possible, and no logging should hapen after. */
/proc/shutdown_logging()
#ifdef EXTOOLS_LOGGING
	extools_finalize_logging()
#else
	rustg_log_close_all()
#endif


/* Helper procs for building detailed log lines */
/proc/key_name(whom, include_link = null, include_name = TRUE)
	var/mob/M
	var/client/C
	var/key
	var/ckey
	var/fallback_name

	if(!whom)
		return "*null*"
	if(istype(whom, /client))
		C = whom
		M = C.mob
		key = C.key
		ckey = C.ckey
	else if(ismob(whom))
		M = whom
		C = M.client
		key = M.key
		ckey = M.ckey
	else if(istext(whom))
		key = whom
		ckey = ckey(whom)
		C = GLOB.directory[ckey]
		if(C)
			M = C.mob
	else if(istype(whom,/datum/mind))
		var/datum/mind/mind = whom
		key = mind.key
		ckey = ckey(key)
		if(mind.current)
			M = mind.current
			if(M.client)
				C = M.client
		else
			fallback_name = mind.name
	else // Catch-all cases if none of the types above match
		var/swhom = null

		if(istype(whom, /atom))
			var/atom/A = whom
			swhom = "[A.name]"
		else if(istype(whom, /datum))
			swhom = "[whom]"

		if(!swhom)
			swhom = "*invalid*"

		return "\[[swhom]\]"

	. = ""

	if(!ckey)
		include_link = FALSE

	if(key)
		if(C && C.holder && C.holder.fakekey && !include_name)
			if(include_link)
				. += "<a href='?priv_msg=[C.findStealthKey()]'>"
			. += "Administrator"
		else
			if(include_link)
				. += "<a href='?priv_msg=[ckey]'>"
			. += key
		if(!C)
			. += "\[DC\]"

		if(include_link)
			. += "</a>"
	else
		. += "*no key*"

	if(include_name)
		if(M)
			if(M.real_name)
				. += "/([M.real_name])"
			else if(M.name)
				. += "/([M.name])"
		else if(fallback_name)
			. += "/([fallback_name])"

	return .

/proc/key_name_admin(whom, include_name = TRUE)
	return key_name(whom, TRUE, include_name)

/proc/loc_name(atom/A)
	if(!istype(A))
		return "(INVALID LOCATION)"

	var/turf/T = A
	if (!istype(T))
		T = get_turf(A)

	if(istype(T))
		return "([AREACOORD(T)])"
	else if(A.loc)
		return "(UNKNOWN (?, ?, ?))"

/proc/atom_loc_line(var/atom/a)
	if(!istype(a))
		return
	var/turf/t = get_turf(a)
	if(istype(t))
		return "[a.loc] ([t.x],[t.y],[t.z]) ([a.loc.type])"
	else if(a.loc)
		return "[a.loc] (0,0,0) ([a.loc.type])"

/proc/log_type_to_name(message_type)
	switch(message_type)
		if(LOG_ATTACK)
			return "Attack"
		if(LOG_SAY)
			return "Say"
		if(LOG_WHISPER)
			return "Whisper"
		if(LOG_EMOTE)
			return "Emote"
		if(LOG_SUBTLER)
			return "Subtler"
		if(LOG_DSAY)
			return "Deadchat"
		if(LOG_PDA)
			return "PDA"
		if(LOG_CHAT)
			return "Chat"
		if(LOG_COMMENT)
			return "Comment"
		if(LOG_TELECOMMS)
			return "Telecomms"
		if(LOG_OOC)
			return "OOC"
		if(LOG_ADMIN)
			return "Admin"
		if(LOG_ADMIN_PRIVATE)
			return "Admin"
		if(LOG_ASAY)
			return "ASAY"
		if(LOG_OWNERSHIP)
			return "Ownership"
		if(LOG_GAME)
			return "Game"
		if(LOG_VIRUS)
			return "Virus"
		if(LOG_MECHA)
			return "Mecha"
		if(LOG_SHUTTLE)
			return "Shuttle"
		if(LOG_VICTIM)
			return "Victim"
		if(LOG_ECON)
			return "Economy"
		if(LOG_UPLINK)
			return "Uplink"
	return "Misc"
