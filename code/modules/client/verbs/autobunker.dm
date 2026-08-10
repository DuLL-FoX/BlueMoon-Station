/client/verb/bunker_auto_authorize()
	set name = "Auto Authorize Panic Bunker"
	set desc = "Authorizes your account in the panic bunker of any servers connected to this function."
	set category = "OOC"
	
	if(prefs.db_flags & DB_FLAG_AGE_CONFIRMATION_INCOMPLETE)
		to_chat(src, "<span class='danger'>You are not age verified.</span>")
		return
		
	if(autobunker_last_try + 5 SECONDS > world.time)
		to_chat(src, "<span class='danger'>Function on cooldown, try again in 5 seconds.</span>")
		return
	autobunker_last_try = world.time

	world.send_cross_server_bunker_overrides(key, src)

/world/proc/send_cross_server_bunker_overrides(key, client/C)
	var/comms_key = CONFIG_GET(string/comms_key)
	if(!comms_key)
		return
	var/list/message = list("ckey" = ckey(key))
	var/source = CONFIG_GET(string/cross_comms_name) || world.name
	var/list/servers = CONFIG_GET(keyed_list/cross_server_bunker_override)
	if(!length(servers))
		to_chat(C, "<span class='boldwarning'>AUTOBUNKER: No servers are configured to receive from this one.</span>")
		return
	log_admin("[key] ([key_name(C)]) has initiated an autobunker authentication with linked servers.")
	for(var/name in servers)
		// Это BYOND Topic, не HTTP: rust-g его не понимает. Вызов всё ещё синхронно
		// останавливает мир, поэтому держим его в явной измеряемой обёртке.
		var/list/result = tracked_byond_topic_request(servers[name], "auto_bunker_override", comms_key, source, message, "автобункер [name]")
		if(QDELETED(C))
			return
		switch(result["statuscode"])
			if(401)
				to_chat(C, "<span class='boldwarning'>AUTOBuNKER: [name] failed to authenticate with this server.</span>")
			if(403)
				to_chat(C, "<span class='boldwarning'>AUTOBUNKER: [name] has autobunker receive disabled.</span>")
			if(200)
				to_chat(C, "<span class='boldwarning'>AUTOBUNKER: Successfully authenticated with [name]. Panic bunker bypass granted to [key].</span>.")
			else
				to_chat(C, "<span class='boldwarning'>AUTOBUNKER: [name] failed: [result["response"]] ([result["statuscode"]]).</span>")
