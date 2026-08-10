GLOBAL_LIST_EMPTY(topic_tokens)
GLOBAL_PROTECT(topic_tokens)

GLOBAL_LIST_EMPTY(topic_commands)
GLOBAL_PROTECT(topic_commands)

#define WORLD_TOPIC_REPLAY_CACHE_LIMIT 256
#define WORLD_TOPIC_REPLAY_RESPONSE_MAX_SIZE 1048576
#define WORLD_TOPIC_REPLAY_CACHE_MAX_SIZE 8388608

SUBSYSTEM_DEF(topic)
	name = "Topic"
	init_order = INIT_ORDER_FAIL2TOPIC
	flags = SS_NO_FIRE
	/// Completed authenticated requests, keyed by a hash of auth token and request id.
	var/list/replay_responses = list()
	/// FIFO ordering for bounded replay_responses eviction.
	var/list/replay_order = list()
	/// Total bytes retained by replay_responses.
	var/replay_response_bytes = 0
	/// Requests which are currently sleeping inside a handler (usually on a DB query).
	var/list/inflight_requests = list()

/datum/controller/subsystem/topic/Initialize(timeofday)
	GLOB.topic_commands = list()
	GLOB.topic_tokens = list()
	replay_responses = list()
	replay_order = list()
	replay_response_bytes = 0
	inflight_requests = list()

	// Store typepaths, not mutable handler instances. Topic handlers may sleep and must
	// never share response state with a concurrent request.
	var/list/anonymous_functions = list()
	var/list/cross_server_functions = list()
	for(var/path in subtypesof(/datum/world_topic))
		var/datum/world_topic/topic_path = path
		var/topic_key = initial(topic_path.key)
		if(!istext(topic_key) || !length(topic_key))
			continue
		if(GLOB.topic_commands[topic_key])
			stack_trace("World Topic handlers [GLOB.topic_commands[topic_key]] and [path] both use key '[topic_key]'; [path] was ignored.")
			continue
		GLOB.topic_commands[topic_key] = path
		if(initial(topic_path.anonymous))
			anonymous_functions[topic_key] = TRUE
		if(initial(topic_path.cross_server))
			cross_server_functions[topic_key] = TRUE

	// Setup the anonymous access token
	GLOB.topic_tokens["anonymous"] = anonymous_functions

	// Parse and setup authed tokens from config
	var/list/tokens = CONFIG_GET(keyed_list/topic_tokens)
	for(var/token in tokens)
		if(token == "anonymous")
			stack_trace("TOPIC_TOKEN may not replace the reserved anonymous token.")
			continue
		var/list/keys = list()
		if(tokens[token] == "all")
			for(var/key in GLOB.topic_commands)
				keys[key] = TRUE
		else
			for(var/key in splittext(tokens[token], ","))
				key = trim(key)
				if(!GLOB.topic_commands[key])
					stack_trace("TOPIC_TOKEN '[token]' grants unknown endpoint '[key]'; the grant was ignored.")
					continue
				keys[key] = TRUE
			// Grant access to anonymous topic calls (version, authed functions etc.) by default
			keys |= anonymous_functions
		GLOB.topic_tokens[token] = keys

	// Existing cross-server deployments already share COMMS_KEY. Restrict that key to
	// the migrated cross-comms endpoints instead of requiring a second secret rollout.
	var/comms_key = CONFIG_GET(string/comms_key)
	if(comms_key == "anonymous")
		stack_trace("COMMS_KEY may not use the reserved anonymous Topic token; cross-server Topic endpoints were not enabled.")
	else if(comms_key)
		var/list/comms_functions = cross_server_functions.Copy()
		comms_functions |= anonymous_functions
		if(GLOB.topic_tokens[comms_key])
			GLOB.topic_tokens[comms_key] |= comms_functions
		else
			GLOB.topic_tokens[comms_key] = comms_functions

	return ..()

/datum/controller/subsystem/topic/proc/replay_key(auth, req_id)
	return md5("[auth]\n[req_id]")

/datum/controller/subsystem/topic/proc/get_replay_response(cache_key)
	return replay_responses[cache_key]

/datum/controller/subsystem/topic/proc/is_request_inflight(cache_key)
	return !!inflight_requests[cache_key]

/datum/controller/subsystem/topic/proc/start_request(cache_key)
	inflight_requests[cache_key] = TRUE

/datum/controller/subsystem/topic/proc/finish_request(cache_key, encoded_response)
	inflight_requests -= cache_key
	if(!istext(encoded_response) || length(encoded_response) > WORLD_TOPIC_REPLAY_RESPONSE_MAX_SIZE)
		return
	var/response_size = length(encoded_response)
	while(length(replay_order) && (length(replay_order) >= WORLD_TOPIC_REPLAY_CACHE_LIMIT || replay_response_bytes + response_size > WORLD_TOPIC_REPLAY_CACHE_MAX_SIZE))
		var/oldest_key = replay_order[1]
		replay_order.Cut(1, 2)
		replay_response_bytes -= length(replay_responses[oldest_key])
		replay_responses -= oldest_key
	replay_responses[cache_key] = encoded_response
	replay_order += cache_key
	replay_response_bytes += response_size

/datum/controller/subsystem/topic/proc/abort_request(cache_key)
	inflight_requests -= cache_key

/datum/config_entry/keyed_list/topic_tokens
	key_mode = KEY_MODE_TEXT
	value_mode = VALUE_MODE_TEXT
	protection = CONFIG_ENTRY_HIDDEN|CONFIG_ENTRY_LOCKED

/datum/config_entry/keyed_list/topic_tokens/ValidateListEntry(key_name, key_value)
	return length(key_name) && key_name != "anonymous" && key_name != "topic_token" && length(key_value) && ..()

#undef WORLD_TOPIC_REPLAY_CACHE_LIMIT
#undef WORLD_TOPIC_REPLAY_RESPONSE_MAX_SIZE
#undef WORLD_TOPIC_REPLAY_CACHE_MAX_SIZE
