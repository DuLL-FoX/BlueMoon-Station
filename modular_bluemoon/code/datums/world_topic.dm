/proc/world_topic_response(statuscode, response_message, data, req_id)
	var/list/result = list(
		"statuscode" = statuscode,
		"response" = response_message,
	)
	if(!isnull(data))
		result["data"] = data
	if(!isnull(req_id))
		result["req_id"] = req_id
	return json_encode(result)

/// Builds the JSON envelope used by both external bot calls and server-to-server Topic calls.
/proc/build_world_topic_query(query, auth, source, list/payload, req_id)
	var/list/request = islist(payload) ? payload.Copy() : list()
	request["query"] = query
	request["auth"] = auth
	request["source"] = source
	request["req_id"] = req_id || rustg_generate_uuid_v4()
	return rustg_url_encode(json_encode(request))

/proc/decode_world_topic_response(raw_response, expected_req_id)
	if(!istext(raw_response) || !rustg_json_is_valid(raw_response))
		return
	var/list/decoded = json_decode(raw_response)
	if(!islist(decoded) || !isnum(decoded["statuscode"]) || !istext(decoded["response"]))
		return
	if(expected_req_id && decoded["req_id"] != expected_req_id)
		return
	return decoded

/// Performs a measured BYOND Topic request and always returns a structured response.
/proc/tracked_byond_topic_request(server_url, query, auth, source, list/payload, desc)
	var/req_id = rustg_generate_uuid_v4()
	var/encoded_query = build_world_topic_query(query, auth, source, payload, req_id)
	var/raw_response = tracked_byond_topic_export("[server_url]?[encoded_query]", desc)
	var/list/decoded = decode_world_topic_response(raw_response, req_id)
	if(decoded)
		return decoded
	return list(
		"statuscode" = 502,
		"response" = isnull(raw_response) ? "No response from remote server" : "Invalid response from remote server",
		"req_id" = req_id,
	)

/proc/is_valid_discord_id(value)
	if(!istext(value) || length(value) < 5 || length(value) > 25)
		return FALSE
	for(var/index in 1 to length(value))
		var/character = text2ascii(value, index)
		if(character < 48 || character > 57)
			return FALSE
	return TRUE

/proc/world_topic_ckey(value)
	if(!istext(value))
		return
	return ckey(value)

/datum/world_topic
	/// query key
	var/key

	/// can be used with anonymous authentication
	var/anonymous = FALSE
	/// may be authenticated by the legacy COMMS_KEY compatibility token
	var/cross_server = FALSE

	var/list/required_params = list()
	var/statuscode
	var/response
	var/data

/datum/world_topic/proc/CheckParams(list/params)
	var/list/missing_params = list()
	var/errorcount = 0

	for(var/param in required_params)
		if(!(param in params) || isnull(params[param]))
			errorcount++
			missing_params += param

	if(errorcount)
		statuscode = 400
		response = "Bad Request - Missing parameters"
		data = missing_params
		return errorcount

/datum/world_topic/proc/Run(list/input)
	// Always returns true; actual details in statuscode, response and data variables
	return TRUE

// API INFO TOPICS

/datum/world_topic/api_get_authed_functions
	key = "api_get_authed_functions"
	anonymous = TRUE

/datum/world_topic/api_get_authed_functions/Run(list/input)
	. = ..()
	var/list/functions = GLOB.topic_tokens[input["auth"]]
	if(functions)
		statuscode = 200
		response = "Authorized functions retrieved"
		data = functions
	else
		statuscode = 401
		response = "Unauthorized - No functions found"
		data = null

// TOPICS

/datum/world_topic/ping
	key = "ping"
	anonymous = TRUE

/datum/world_topic/ping/Run(list/input)
	. = ..()
	statuscode = 200
	response = "Pong!"
	data = length(GLOB.clients)

// CROSS-SERVER TOPICS

/datum/world_topic/cross_server
	cross_server = TRUE

/datum/world_topic/cross_server/message
	required_params = list("message_sender", "message")

/datum/world_topic/cross_server/message/CheckParams(list/params)
	. = ..()
	if(.)
		return
	if(!istext(params["message_sender"]) || !istext(params["message"]))
		statuscode = 400
		response = "Bad Request - Invalid message payload"
		return TRUE

/datum/world_topic/cross_server/message/ahelp
	key = "Ahelp"

/datum/world_topic/cross_server/message/ahelp/Run(list/input)
	relay_msg_admins("<span class='adminnotice'><b><font color=red>HELP: </font> [sanitize(input["source"])] [sanitize(input["message_sender"])]: [sanitize(input["message"])]</b></span>")
	statuscode = 200
	response = "Message relayed"

/datum/world_topic/cross_server/message/comms_console
	key = "Comms_Console"

/datum/world_topic/cross_server/message/comms_console/Run(list/input)
	minor_announce(sanitize(input["message"]), "Incoming message from [sanitize(input["message_sender"])]")
	for(var/obj/machinery/computer/communications/console in GLOB.machines)
		console.override_cooldown()
	statuscode = 200
	response = "Message relayed"

/datum/world_topic/cross_server/message/news_report
	key = "News_Report"

/datum/world_topic/cross_server/message/news_report/Run(list/input)
	minor_announce(sanitize(input["message"]), "Breaking Update From [sanitize(input["message_sender"])]")
	statuscode = 200
	response = "Message relayed"

/datum/world_topic/cross_server/auto_bunker
	key = "auto_bunker_override"
	required_params = list("ckey")

/datum/world_topic/cross_server/auto_bunker/Run(list/input)
	if(!CONFIG_GET(flag/allow_cross_server_bunker_override))
		statuscode = 403
		response = "Function Disabled"
		return
	var/ckey_to_bypass = world_topic_ckey(input["ckey"])
	if(!ckey_to_bypass)
		statuscode = 400
		response = "Invalid ckey"
		return
	var/is_new_ckey = !(ckey_to_bypass in GLOB.bunker_passthrough)
	GLOB.bunker_passthrough |= ckey_to_bypass
	GLOB.bunker_passthrough[ckey_to_bypass] = world.realtime
	SSpersistence.SavePanicBunker()
	if(is_new_ckey)
		var/sender = sanitize(input["source"])
		log_admin("AUTO BUNKER: [ckey_to_bypass] given access (incoming comms from [sender]).")
		message_admins("AUTO BUNKER: [ckey_to_bypass] given access (incoming comms from [sender]).")
		send2adminchat("Panic Bunker", "AUTO BUNKER: [ckey_to_bypass] given access (incoming comms from [sender]).")
	statuscode = 200
	response = "Success"

/datum/world_topic/status
	key = "status"
	anonymous = TRUE

/datum/world_topic/status/Run(list/input)
	. = ..()

	data = list()

	data["mode"] = "hidden"

	data["round_id"] = null
	if(GLOB.round_id)
		data["round_id"] = GLOB.round_id

	data["enter"] = GLOB.enter_allowed

	data["map_name"] = null
	if(SSmapping.config)
		data["map_name"] = SSmapping.config.map_name

	data["players"] = length(GLOB.clients)

	data["revision"] = GLOB.revdata?.commit
	data["revision_date"] = GLOB.revdata?.date

	data["round_duration"] = SSticker ? world.time - SSticker.round_start_time : 0

	statuscode = 200
	response = "Status retrieved"

/datum/world_topic/status/authed
	key = "status_authed"
	anonymous = FALSE

/datum/world_topic/status/authed/Run(list/input)
	. = ..()
	data["mode"] = GLOB.master_mode

	var/list/adm = get_admin_counts()
	var/list/presentmins = adm["present"]
	var/list/afkmins = adm["afk"]
	data["admins"] = length(presentmins) + length(afkmins)
	data["gamestate"] = SSticker?.current_state

	//Time dilation stats.
	data["time_dilation_current"] = SStime_track.time_dilation_current
	data["time_dilation_avg"] = SStime_track.time_dilation_avg
	data["time_dilation_avg_slow"] = SStime_track.time_dilation_avg_slow
	data["time_dilation_avg_fast"] = SStime_track.time_dilation_avg_fast

	data["mcpu"] = world.map_cpu
	data["cpu"] = world.cpu

/datum/world_topic/certify
	key = "certify"
	required_params = list("identifier", "discord_id")

/datum/world_topic/certify/Run(list/input)
	data = list()

	statuscode = 500
	response = "Something went wrong, address issues."

	if(!istext(input["identifier"]) || !length(input["identifier"]))
		statuscode = 400
		response = "Invalid authentication identifier."
		return
	if(!istext(input["discord_id"]))
		statuscode = 400
		response = "Discord ID must be a string."
		return
	var/discord_id = input["discord_id"]
	if(!is_valid_discord_id(discord_id))
		statuscode = 400
		response = "Invalid Discord ID."
		return

	var/datum/discord_link_record/player_link = SSdiscord.find_discord_link_by_token(input["identifier"])
	if(!player_link)
		statuscode = 500
		response = "Database query failed"
		return

	var/datum/discord_link_record/player_link_timebound = SSdiscord.find_discord_link_by_token(input["identifier"], TRUE)
	if(!player_link_timebound)
		statuscode = 501
		response = "Authentication timed out."
		return

	if(player_link.discord_id)
		statuscode = 503
		response = "Player already authenticated."
		return

	var/datum/discord_link_record/id_player_link = SSdiscord.find_discord_link_by_discord_id(discord_id)
	if(id_player_link)
		statuscode = 504
		response = "Discord ID already verified."
		return

	var/datum/db_query/query = SSdbcore.NewQuery(
		"UPDATE [format_table_name("discord_links")] SET valid = 1, discord_id = :discord_id WHERE one_time_token = :token",
		list("discord_id" = discord_id, "token" = input["identifier"])
	)
	if(!query.warn_execute())
		qdel(query)
		response = "Database query failed"
		return
	qdel(query)

	statuscode = 200
	response = "Successfully certified."

/datum/world_topic/certify_by_ckey
	key = "certify_ckey"
	required_params = list("ckey", "discord_id")

/datum/world_topic/certify_by_ckey/Run(list/input)
	data = list()

	statuscode = 500
	response = "Something went wrong, address issues."

	if(!istext(input["discord_id"]))
		statuscode = 400
		response = "Discord ID must be a string."
		return
	var/discord_id = input["discord_id"]
	var/player_ckey = world_topic_ckey(input["ckey"])
	if(!player_ckey || !is_valid_discord_id(discord_id))
		statuscode = 400
		response = "Invalid ckey or Discord ID."
		return

	var/datum/discord_link_record/player_link = SSdiscord.find_discord_link_by_ckey(player_ckey)
	if(player_link && player_link.discord_id)
		statuscode = 503
		response = "Player already authenticated."
		return

	var/datum/discord_link_record/id_player_link = SSdiscord.find_discord_link_by_discord_id(discord_id)
	if(id_player_link)
		statuscode = 504
		response = "Discord ID already verified."
		return

	var/datum/db_query/query
	if(player_link)
		query = SSdbcore.NewQuery(
			"UPDATE [format_table_name("discord_links")] SET valid = 1, discord_id = :discord_id WHERE ckey = :ckey",
			list("discord_id" = discord_id, "ckey" = player_ckey)
		)
	else
		query = SSdbcore.NewQuery(
			"INSERT INTO [format_table_name("discord_links")] (ckey, discord_id, valid) VALUES (:ckey, :discord_id, 1)",
			list("ckey" = player_ckey, "discord_id" = discord_id)
		)

	if(!query.warn_execute())
		qdel(query)
		response = "Database query failed"
		return
	qdel(query)

	statuscode = 200
	response = "Successfully certified."

/datum/world_topic/decertify_by_ckey
	key = "decertify_ckey"
	required_params = list("ckey")

/datum/world_topic/decertify_by_ckey/Run(list/input)
	data = list()

	statuscode = 500
	response = "Something went wrong, address issues."

	var/player_ckey = world_topic_ckey(input["ckey"])
	if(!player_ckey)
		statuscode = 400
		response = "Invalid ckey."
		return
	var/datum/discord_link_record/player_link = SSdiscord.find_discord_link_by_ckey(player_ckey)
	if(!player_link)
		statuscode = 500
		response = "Database lookup failed."
		return

	if(!player_link.discord_id)
		statuscode = 501
		response = "No linked Discord."
		return

	var/datum/db_query/query = SSdbcore.NewQuery(
		"DELETE FROM [format_table_name("discord_links")] WHERE ckey = :ckey",
		list("ckey" = player_link.ckey)
	)
	if(!query.warn_execute())
		qdel(query)
		response = "Database query failed"
		return
	qdel(query)

	data["discord_id"] = player_link.discord_id
	data["ckey"] = player_link.ckey
	statuscode = 200
	response = "Decertification successful."

/datum/world_topic/decertify_by_discord_id
	key = "decertify_discord_id"
	required_params = list("discord_id")

/datum/world_topic/decertify_by_discord_id/Run(list/input)
	data = list()

	statuscode = 500
	response = "Something went wrong, address issues."

	if(!istext(input["discord_id"]))
		statuscode = 400
		response = "Discord ID must be a string."
		return
	var/discord_id = input["discord_id"]
	if(!is_valid_discord_id(discord_id))
		statuscode = 400
		response = "Invalid Discord ID."
		return

	var/datum/discord_link_record/player_link = SSdiscord.find_discord_link_by_discord_id(discord_id)
	if(!player_link)
		statuscode = 500
		response = "Database lookup failed."
		return

	var/datum/db_query/query = SSdbcore.NewQuery(
		"DELETE FROM [format_table_name("discord_links")] WHERE ckey = :ckey",
		list("ckey" = player_link.ckey)
	)
	if(!query.warn_execute())
		qdel(query)
		response = "Database query failed"
		return
	qdel(query)

	data["discord_id"] = player_link.discord_id
	data["ckey"] = player_link.ckey
	statuscode = 200
	response = "Decertification successful."

/datum/world_topic/lookup_discord_id
	key = "lookup_discord_id"
	required_params = list("discord_id")

/datum/world_topic/lookup_discord_id/Run(list/input)
	data = list()

	statuscode = 500
	response = "Something went wrong, address issues."

	if(!istext(input["discord_id"]))
		statuscode = 400
		response = "Discord ID must be a string."
		return
	var/discord_id = input["discord_id"]
	if(!is_valid_discord_id(discord_id))
		statuscode = 400
		response = "Invalid Discord ID."
		return

	var/datum/discord_link_record/player_link = SSdiscord.find_discord_link_by_discord_id(discord_id)
	if(!player_link)
		statuscode = 501
		response = "No linked Discord."
		return

	data["ckey"] = player_link.ckey
	data["discord_id"] = player_link.discord_id
	if(input["additional"] && !request_additional_data(data))
		statuscode = 500
		response = "Additional data query failed."
		return
	statuscode = 200
	response = "Lookup successful."

/datum/world_topic/ban
	key = "ban_ckey"
	required_params = list("ckey", "ban_data")
	var/datum/admins/our_solution

/datum/world_topic/ban/New()
	our_solution = new (forced_holder = TRUE)

/datum/world_topic/ban/Destroy()
	QDEL_NULL(our_solution)
	return ..()

/datum/world_topic/ban/Run(list/input)
	data = list()

	statuscode = 500
	response = "Something went wrong, address issues."

	if(!islist(input["ban_data"]))
		statuscode = 400
		response = "Invalid ban data."
		return
	var/list/raw_ban_data = input["ban_data"]
	var/list/ban_data = raw_ban_data.Copy()
	var/target_ckey = world_topic_ckey(input["ckey"])
	if(!target_ckey || (ban_data["ckey"] && world_topic_ckey(ban_data["ckey"]) != target_ckey))
		statuscode = 400
		response = "Invalid or mismatched ckey."
		return
	ban_data["ckey"] = target_ckey
	if(!isnull(ban_data["job"]) && !islist(ban_data["job"]))
		statuscode = 400
		response = "Invalid job ban data."
		return
	if(!istext(ban_data["reason"]) || !length(ban_data["reason"]) || !istext(ban_data["admin_id"]) || !length(ban_data["admin_id"]))
		statuscode = 400
		response = "Missing ban reason or admin ID."
		return
	for(var/job_name in ban_data["job"])
		if(!istext(job_name))
			statuscode = 400
			response = "Invalid job ban data."
			return
	// Make sure we got NUMBERS
	if((!isnum(ban_data["bantype"]) && !istext(ban_data["bantype"])) || (!isnum(ban_data["duration"]) && !istext(ban_data["duration"])))
		statuscode = 400
		response = "Invalid ban type or duration."
		return
	ban_data["bantype"] = text2num("[ban_data["bantype"]]")
	ban_data["duration"] = text2num("[ban_data["duration"]]")
	if(isnull(ban_data["bantype"]) || isnull(ban_data["duration"]) || ban_data["duration"] < 0)
		statuscode = 400
		response = "Invalid ban type or duration."
		return
	var/mob/playermob
	for(var/mob/M in GLOB.player_list)
		if(M.ckey == ban_data["ckey"])
			if(!playermob || M.client) // prioritise mobs with a client to stop the 'oops the dead body with no client got forwarded'
				playermob = M

	if(ban_data["job"])
		var/list/joblist = list()
		for(var/name in ban_data["job"])
			switch (name)
				if("commanddept")
					joblist += GLOB.command_positions
				if("securitydept")
					joblist += GLOB.security_positions
				if("engineeringdept")
					joblist += GLOB.engineering_positions
				if("medicaldept")
					joblist += GLOB.medical_positions
				if("sciencedept")
					joblist += GLOB.science_positions
				if("supplydept")
					joblist += GLOB.supply_positions
				if("civiliandept")
					joblist += GLOB.civilian_positions
				if("lawdept")
					joblist += GLOB.law_positions
				if("nonhumandept")
					joblist += GLOB.nonhuman_positions
				if("ghostroles")
					joblist += list(ROLE_PAI, ROLE_POSIBRAIN, ROLE_DRONE , ROLE_DEATHSQUAD, ROLE_LAVALAND, ROLE_SENTIENCE)
				if("teamantags")
					joblist += list(ROLE_OPERATIVE, ROLE_REV, ROLE_CULTIST, ROLE_SERVANT_OF_RATVAR, ROLE_ABDUCTOR, ROLE_ALIEN, ROLE_FAMILIES)
				if("convertantags")
					joblist += list(ROLE_REV, ROLE_CULTIST, ROLE_SERVANT_OF_RATVAR, ROLE_ALIEN)
				if("otherroles")
					joblist += list(ROLE_MIND_TRANSFER)
				else
					joblist += name

		var/list/notbannedlist = list()
		if(playermob)
			for(var/job in joblist)
				if(!jobban_isbanned(playermob, job))
					notbannedlist += job
		else
			notbannedlist = joblist

		if(!length(notbannedlist))
			statuscode = 409
			response = "Player is already banned from every requested role."
			return

		var/ban_time_text = ban_data["duration"] > 0 ? "for [ban_data["duration"]] minutes" : " permamently"
		var/msg
		for(var/job in notbannedlist)
			var/result_of_run = our_solution.DB_ban_record(ban_data["bantype"], playermob, ban_data["duration"], ban_data["reason"], job, ban_data["ckey"], forced_holder = TRUE)
			if(result_of_run != TRUE)
				statuscode = 501
				response = result_of_run ? result_of_run : "Failed to apply ban."
				return
			if(playermob?.client)
				jobban_buildcache(playermob.client)
			ban_unban_log_save("[ban_data["admin_id"]] (DISCORD ID) jobbanned [ban_data["ckey"]] from [job] [ban_time_text]. reason: [ban_data["reason"]]")
			log_admin_private("[ban_data["admin_id"]] (DISCORD ID) jobbanned [ban_data["ckey"]] from [job] [ban_time_text].")
			if(!msg)
				msg = job
			else
				msg += ", [job]"
		create_message("note", ban_data["ckey"], null, "Banned  from [msg] - [ban_data["reason"]]", null, null, 0, 0, null, 0, ban_data["severity"] || "None", dont_announce_to_events = TRUE)
		message_admins("<span class='adminnotice'>[ban_data["admin_id"]] (DISCORD ID) banned [ban_data["ckey"]] from [msg] [ban_time_text].</span>")
		if(playermob)
			to_chat(playermob, "<span class='boldannounce'><BIG>You have been jobbanned by [ban_data["admin_id"]] (DISCORD ID) from: [msg]\n[ban_time_text].</BIG></span>")
			to_chat(playermob, "<span class='boldannounce'>The reason is: [ban_data["reason"]]</span>")

		GLOB.bot_event_sending_que += list(list(
			"type" = "ban_a",
			"title" = ban_data["duration"] > 0 ? "Блокировка Роли" : "Пермаментная Блокировка Роли",
			"player" = ban_data["ckey"],
			"admin" = ban_data["admin_id"],
			"reason" = ban_data["reason"],
			"banduration" = ban_data["duration"] > 0 ? ban_data["duration"] : null,
			"bantimestamp" = SQLtime(),
			"round" = GLOB.round_id,
			"additional_info" = list("ban_job" = msg)
		))

	else
		var/result_of_run = our_solution.DB_ban_record(ban_data["bantype"], playermob, ban_data["duration"], ban_data["reason"], null, ban_data["ckey"], forced_holder = TRUE)
		if(result_of_run != TRUE)
			statuscode = 501
			response = result_of_run ? result_of_run : "Failed to apply ban."
			return
		var/ban_time_text = ban_data["duration"] > 0 ? "For [ban_data["duration"]] minutes." : "This is a permanent ban."
		ban_unban_log_save("[ban_data["admin_id"]] (DISCORD ID) has banned [ban_data["ckey"]].\nReason: [ban_data["reason"]]\n[ban_time_text]")
		log_admin_private("[ban_data["admin_id"]] (DISCORD ID) has banned [ban_data["ckey"]].\nReason: [ban_data["reason"]]\n[ban_time_text]")
		create_message("note", ban_data["ckey"], null, ban_data["reason"], null, null, 0, 0, null, 0, ban_data["severity"] || "None", dont_announce_to_events = TRUE)
		if(playermob)
			qdel(playermob.client)

		GLOB.bot_event_sending_que += list(list(
			"type" = "ban_a",
			"title" = ban_data["duration"] > 0 ? "Блокировка" : "Пермаментная Блокировка",
			"player" = ban_data["ckey"],
			"admin" = ban_data["admin_id"],
			"reason" = ban_data["reason"],
			"banduration" = ban_data["duration"] > 0 ? ban_data["duration"] : null,
			"bantimestamp" = SQLtime(),
			"round" = GLOB.round_id,
			"additional_info" = list()
		))

	statuscode = 200
	response = "Ban successful."

/datum/world_topic/lookup_ckey
	key = "lookup_ckey"
	required_params = list("ckey")

/datum/world_topic/lookup_ckey/Run(list/input)
	data = list()

	statuscode = 500
	response = "Something went wrong, address issues."

	var/player_ckey = world_topic_ckey(input["ckey"])
	if(!player_ckey)
		statuscode = 400
		response = "Invalid ckey."
		return

	var/datum/db_query/query_player_ckey = SSdbcore.NewQuery({"
		SELECT ckey
		FROM [format_table_name("player")]
		WHERE ckey = :ckey"},
		list("ckey" = player_ckey)
	)

	var/seen_before
	if(!query_player_ckey.warn_execute())
		qdel(query_player_ckey)
		response = "Database query failed."
		return
	seen_before = query_player_ckey.NextRow()

	var/datum/discord_link_record/player_link = SSdiscord.find_discord_link_by_ckey(player_ckey)
	if(!player_link && !seen_before)
		statuscode = 501
		response = "Not found player."
		qdel(query_player_ckey)
		return

	data["ckey"] = player_link ? player_link.ckey : query_player_ckey.item[1]
	data["discord_id"] = player_link ? player_link.discord_id : FALSE
	qdel(query_player_ckey)
	if(input["additional"] && !request_additional_data(data))
		statuscode = 500
		response = "Additional data query failed."
		return
	statuscode = 200
	response = "Lookup successful."

/proc/request_additional_data(list/data)
	var/succeeded = TRUE
	//BANS
	var/datum/db_query/query_search_bans = SSdbcore.NewQuery({"
		SELECT id, bantime, bantype, reason, job, duration, expiration_time, IFNULL((SELECT byond_key FROM [format_table_name("player")] WHERE [format_table_name("player")].ckey = [format_table_name("ban")].ckey), ckey), IFNULL((SELECT byond_key FROM [format_table_name("player")] WHERE [format_table_name("player")].ckey = [format_table_name("ban")].a_ckey), a_ckey), unbanned, IFNULL((SELECT byond_key FROM [format_table_name("player")] WHERE [format_table_name("player")].ckey = [format_table_name("ban")].unbanned_ckey), unbanned_ckey), unbanned_datetime, edits, round_id
		FROM [format_table_name("ban")]
		WHERE ckey = :ckey ORDER BY bantime"}, list("ckey" = data["ckey"]))
	if(query_search_bans.warn_execute())
		data["bans"] = list()
		while(query_search_bans.NextRow())
			if(query_search_bans.item[10])
				continue

			data["bans"] += list(list(
				"bantime" = query_search_bans.item[2],
				"bantype"  = query_search_bans.item[3],
				"reason" = query_search_bans.item[4],
				"job" = query_search_bans.item[5],
				"duration" = query_search_bans.item[6],
				"expiration" = query_search_bans.item[7],
				"round_id" = query_search_bans.item[14]
			))
	else
		succeeded = FALSE
	qdel(query_search_bans)

	//NOTES
	var/datum/db_query/query_get_messages = SSdbcore.NewQuery({"
		SELECT
			IFNULL((SELECT byond_key FROM [format_table_name("player")] WHERE ckey = adminckey), adminckey),
			text,
			timestamp,
			IFNULL((SELECT byond_key FROM [format_table_name("player")] WHERE ckey = lasteditor), lasteditor)
		FROM [format_table_name("messages")]
		WHERE type = :type
		AND deleted = 0
		AND (expire_timestamp > NOW() OR expire_timestamp IS NULL)
		AND targetckey = :targetckey
	"}, list("targetckey" = data["ckey"], "type" = "note"))
	if(query_get_messages.warn_execute())
		data["notes"] = list()
		while(query_get_messages.NextRow())
			data["notes"] += list(list(
				"admin_key" = query_get_messages.item[1],
				"text" = query_get_messages.item[2],
				"timestamp" = query_get_messages.item[3],
				"editor_key" = query_get_messages.item[4]
			))
	else
		succeeded = FALSE
	qdel(query_get_messages)

	var/datum/db_query/exp_read = SSdbcore.NewQuery(
		"SELECT job, minutes FROM [format_table_name("role_time")] WHERE ckey = :ckey",
		list("ckey" = data["ckey"])
	)
	if(exp_read.warn_execute())
		var/list/play_records = list()
		data["playtimes"] = play_records
		while(exp_read.NextRow())
			play_records[exp_read.item[1]] = text2num(exp_read.item[2])
	else
		succeeded = FALSE
	qdel(exp_read)
	return succeeded

GLOBAL_LIST_EMPTY(bot_event_sending_que)
GLOBAL_LIST_EMPTY(bot_ooc_sending_que)
GLOBAL_LIST_EMPTY(bot_asay_sending_que)
GLOBAL_LIST_EMPTY(jobban_bot_batch_global)

/datum/world_topic/receive_info
	key = "receive_info"

/datum/world_topic/receive_info/Run(list/input)
	data = list()
	if(!length(GLOB.bot_event_sending_que) && !length(GLOB.bot_ooc_sending_que) && !length(GLOB.bot_asay_sending_que))
		statuscode = 501
		response = "No events pool."
		return

	//Yeah, we can use /datum/http_request, but nuh... it's less fun.
	data["events"] = GLOB.bot_event_sending_que
	data["ooc"] = GLOB.bot_ooc_sending_que
	data["admin"] = GLOB.bot_asay_sending_que
	GLOB.bot_event_sending_que = list()
	GLOB.bot_ooc_sending_que = list()
	GLOB.bot_asay_sending_que = list()
	statuscode = 200
	response = "Events sent."

/datum/world_topic/send_info
	key = "send_info"
	required_params = list("data")

/datum/world_topic/send_info/Run(list/input)
	data = list()

	var/list/bot_data = input["data"]
	if(!islist(bot_data) || !length(bot_data) || (!isnull(bot_data["ooc"]) && !islist(bot_data["ooc"])) || (!isnull(bot_data["admin"]) && !islist(bot_data["admin"])))
		statuscode = 400
		response = "Wrong data"
		return

	if(bot_data["ooc"])
		for(var/entry in bot_data["ooc"])
			if(!islist(entry) || !istext(entry["author"]) || !istext(entry["message"]))
				continue
			var/msg = sanitize(entry["message"])
			var/author = sanitize(entry["author"])
			for(var/client/C in GLOB.clients)
				if(C.prefs.chat_toggles & CHAT_OOC)
					to_chat(C, "<span class='ooc'><span class='prefix'>DISCORD OOC:</span> <EM>[author]:</EM> <span class='message linkify'>[msg]</span></span>")

	if(bot_data["admin"])
		for(var/entry in bot_data["admin"])
			if(!islist(entry) || !istext(entry["author"]) || !istext(entry["message"]))
				continue
			to_chat(GLOB.admins, "<span class='adminsay'><span class='prefix'>DISCORD ADMIN:</span> <EM>[sanitize(entry["author"])]</EM>: <span class='message linkify'>[sanitize(entry["message"])]</span></span>", confidential = TRUE)

	statuscode = 200
	response = "Events received."
