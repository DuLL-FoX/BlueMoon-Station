/datum/unit_test/world_topic_protocol_helpers/Run()
	var/req_id = "topic-unit-test"
	var/encoded = build_world_topic_query("ping", "anonymous", "unit-test", list("zero" = 0), req_id)
	var/list/request = json_decode(rustg_url_decode(encoded))
	TEST_ASSERT(islist(request), "World Topic request helper must encode a JSON object")
	TEST_ASSERT_EQUAL(request["query"], "ping", "World Topic query must survive encoding")
	TEST_ASSERT_EQUAL(request["auth"], "anonymous", "World Topic auth must survive encoding")
	TEST_ASSERT_EQUAL(request["source"], "unit-test", "World Topic source must survive encoding")
	TEST_ASSERT_EQUAL(request["req_id"], req_id, "World Topic request id must survive encoding")
	TEST_ASSERT_EQUAL(request["zero"], 0, "Falsey payload values must survive encoding")

	var/list/response = decode_world_topic_response(world_topic_response(200, "ok", list("value" = FALSE), req_id), req_id)
	TEST_ASSERT(islist(response), "World Topic response helper must decode its own response")
	TEST_ASSERT_EQUAL(response["statuscode"], 200, "World Topic response status must survive encoding")
	TEST_ASSERT_EQUAL(response["data"]["value"], FALSE, "World Topic response data must preserve falsey values")
	TEST_ASSERT_NULL(decode_world_topic_response(world_topic_response(200, "ok", null, "wrong-id"), req_id), "A response with a mismatched request id must be rejected")

/datum/unit_test/world_topic_required_params_check_presence/Run()
	var/datum/world_topic/cross_server/auto_bunker/handler = new
	TEST_ASSERT(!handler.CheckParams(list("ckey" = "")), "An empty but present parameter must not be reported as missing")
	TEST_ASSERT(!handler.CheckParams(list("ckey" = FALSE)), "A false but present parameter must not be reported as missing")
	TEST_ASSERT(handler.CheckParams(list()), "An absent required parameter must be reported as missing")
	qdel(handler)

/datum/unit_test/world_topic_dispatch_and_replay/Run()
	TEST_ASSERT(ispath(GLOB.topic_commands["ping"]), "World Topic registry must store handler typepaths, not shared mutable instances")

	var/token = "unit-test-topic-token-[rustg_generate_uuid_v4()]"
	var/req_id = rustg_generate_uuid_v4()
	var/list/grants = list("ping" = TRUE)
	var/list/unauthorized = decode_world_topic_response(world.Topic(build_world_topic_query("ping", "bad-[token]", "unit-test", null, req_id), "unit-test-a", null, null), req_id)
	TEST_ASSERT_EQUAL(unauthorized["statuscode"], 401, "An invalid token must be rejected")

	GLOB.topic_tokens[token] = grants
	var/query = build_world_topic_query("ping", token, "unit-test", null, req_id)
	var/first_raw = world.Topic(query, "unit-test-b", null, null)
	var/list/first = decode_world_topic_response(first_raw, req_id)
	TEST_ASSERT_EQUAL(first["statuscode"], 200, "A valid request must not be poisoned by an earlier unauthorized use of its request id")

	var/cache_key = SStopic.replay_key(token, req_id)
	TEST_ASSERT_EQUAL(SStopic.get_replay_response(cache_key), first_raw, "Authenticated Topic response must be stored for safe retry")
	var/second_raw = world.Topic(query, "unit-test-c", null, null)
	TEST_ASSERT_EQUAL(second_raw, first_raw, "A repeated authenticated request must receive the original response")

	GLOB.topic_tokens -= token
	SStopic.replay_response_bytes -= length(SStopic.replay_responses[cache_key])
	SStopic.replay_responses -= cache_key
	SStopic.replay_order -= cache_key
	SStopic.inflight_requests -= cache_key

/datum/unit_test/world_topic_rejects_json_scalars/Run()
	var/list/response = json_decode(world.Topic(rustg_url_encode(json_encode("not-an-object")), "unit-test-scalar", null, null))
	TEST_ASSERT_EQUAL(response["statuscode"], 400, "JSON scalars must be rejected before associative field access")

/datum/unit_test/world_topic_cross_server_sources_use_json_protocol/Run()
	var/list/source_paths = list(
		"code/modules/client/verbs/autobunker.dm",
		"code/modules/admin/verbs/adminhelp.dm",
	)
	for(var/source_path in source_paths)
		var/source = read_source_file(source_path)
		TEST_ASSERT(findtext(source, "tracked_byond_topic_request("), "[source_path] must use the shared JSON BYOND Topic request helper")
		TEST_ASSERT(!findtext(source, "list2params(message)"), "[source_path] must not send the retired params-list Topic protocol")

/datum/unit_test/world_topic_replay_cache_is_bounded/Run()
	var/list/old_responses = SStopic.replay_responses
	var/list/old_order = SStopic.replay_order
	var/list/old_inflight = SStopic.inflight_requests
	var/old_response_bytes = SStopic.replay_response_bytes
	SStopic.replay_responses = list()
	SStopic.replay_order = list()
	SStopic.inflight_requests = list()
	SStopic.replay_response_bytes = 0

	for(var/index in 1 to 257)
		SStopic.finish_request("cache-[index]", "response-[index]")
	TEST_ASSERT_EQUAL(length(SStopic.replay_responses), 256, "World Topic replay cache must have a hard entry limit")
	TEST_ASSERT_NULL(SStopic.get_replay_response("cache-1"), "World Topic replay cache must evict the oldest response")
	TEST_ASSERT_EQUAL(SStopic.get_replay_response("cache-257"), "response-257", "World Topic replay cache must retain the newest response")

	SStopic.replay_responses = old_responses
	SStopic.replay_order = old_order
	SStopic.inflight_requests = old_inflight
	SStopic.replay_response_bytes = old_response_bytes

/datum/unit_test/fail2topic_respects_enabled_flag/Run()
	var/old_enabled = SSfail2topic.enabled
	var/old_rate_limit = SSfail2topic.rate_limit
	var/old_max_fails = SSfail2topic.max_fails
	var/list/old_rate_limiting = SSfail2topic.rate_limiting
	var/list/old_fail_counts = SSfail2topic.fail_counts
	var/list/old_active_bans = SSfail2topic.active_bans
	SSfail2topic.enabled = TRUE
	SSfail2topic.rate_limit = 10
	SSfail2topic.max_fails = 100
	SSfail2topic.rate_limiting = list()
	SSfail2topic.fail_counts = list()
	SSfail2topic.active_bans = list()

	var/test_ip = "unit-test-[rustg_generate_uuid_v4()]"
	TEST_ASSERT(!SSfail2topic.IsRateLimited(test_ip), "The first Topic request in a rate window must pass")
	TEST_ASSERT(SSfail2topic.IsRateLimited(test_ip), "A repeated Topic request inside the configured interval must be limited")
	SSfail2topic.enabled = FALSE
	TEST_ASSERT(!SSfail2topic.IsRateLimited(test_ip), "Disabled fail2topic must not retain or apply rate limiting")

	SSfail2topic.enabled = old_enabled
	SSfail2topic.rate_limit = old_rate_limit
	SSfail2topic.max_fails = old_max_fails
	SSfail2topic.rate_limiting = old_rate_limiting
	SSfail2topic.fail_counts = old_fail_counts
	SSfail2topic.active_bans = old_active_bans

/datum/unit_test/world_topic_identifier_validation/Run()
	TEST_ASSERT(is_valid_discord_id("123456789012345678"), "Discord snowflakes must stay as strings to avoid numeric precision loss")
	TEST_ASSERT(!is_valid_discord_id(123456), "Numeric JSON Discord IDs must be rejected before precision can be lost")
	TEST_ASSERT(!is_valid_discord_id("12x456"), "Discord IDs containing non-digits must be rejected")
	TEST_ASSERT_EQUAL(world_topic_ckey("Example_User"), "exampleuser", "Topic ckeys must use BYOND canonicalization")
	TEST_ASSERT_NULL(world_topic_ckey(list("not", "text")), "Non-text ckeys must be rejected")

/datum/unit_test/world_topic_sql_regressions/Run()
	var/source = read_source_file("modular_bluemoon/code/datums/world_topic.dm")
	TEST_ASSERT(!findtext(source, "DELETE \[format_table_name(\"discord_links\")\]"), "Discord unlink queries must use valid DELETE FROM syntax")
	TEST_ASSERT(findtext(source, "find_discord_link_by_ckey(player_ckey)"), "certify_ckey must look up a ckey, not treat it as a one-time token")
	TEST_ASSERT(findtext(source, "\"type\" = \"note\""), "Additional note lookup must bind its SQL type parameter")
