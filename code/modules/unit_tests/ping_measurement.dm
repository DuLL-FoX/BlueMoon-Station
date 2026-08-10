// Regression tests for the client ping round trip.
//
// Both timestamps in the .update_ping command leave the server as text inside a winset
// command line and come back as verb arguments. Plain string interpolation keeps six
// significant digits, and REALTIMEOFDAY needs all six for its integer part alone from
// 02:47 GMT until midnight - which silently rounded every send stamp to a whole
// decisecond and injected up to 50ms of error into every sample.

/// Every timestamp that goes out over the ping command line has to come back unchanged.
/datum/unit_test/ping_wire_preserves_timestamp/Run()
	// Each stamp is exactly representable as a 32-bit float, so a lossless wire format
	// round-trips it bit for bit and any drift below is the wire format's own doing.
	var/static/list/stamps = list(
		// REALTIMEOFDAY at 21:19 GMT. Six digits stop at the decimal point.
		767600.5,
		// world.time three hours into a round - same overflow, same total loss.
		108000.5,
		// world.time two hours in. One decimal survives, the rest does not.
		72000.0546875,
	)

	for(var/stamp in stamps)
		var/error_ms = abs(text2num(ping_wire_num(stamp)) - stamp) * 100
		TEST_ASSERT_EQUAL(error_ms, 0, "wire round-trip of [num2text(stamp, 12)] moved the timestamp by this many ms")

/// The server share of a round trip is the wall clock's lead over the game clock.
/datum/unit_test/ping_server_component_charges_stall_time/Run()
	// A stall freezes world.time but not the wall clock: 201ms of real time against a
	// game clock that only booked 50ms means 151ms went into the stall, not the wire.
	TEST_ASSERT_EQUAL(ping_server_component(201, 50), 151, "wall time above game time is server stall")

	// An idle server books the same time on both clocks and owes the round trip nothing.
	TEST_ASSERT_EQUAL(ping_server_component(3, 3), 0, "matching clocks must charge the server nothing")

	// The game clock cannot outrun the wall clock, so a negative gap is measurement
	// noise from the intra-tick estimate rather than negative server time.
	TEST_ASSERT_EQUAL(ping_server_component(3, 5), 0, "noise must not produce negative server time")

/// A resource-loading outlier must not remain in the player-facing average after the
/// interface and native command channel have both proved ready.
/datum/unit_test/ping_display_average_drops_login_outlier/Run()
	TEST_ASSERT_EQUAL(ping_display_average(null, 900), 900, "the first stable sample must seed the display")
	TEST_ASSERT_EQUAL(ping_display_average(900, 8, TRUE), 8, "UI readiness must discard resource-loading history")
	TEST_ASSERT_EQUAL(ping_display_average(100, 50), MC_AVERAGE_FAST(100, 50), "ordinary updates must use the fast filtered average")

/// Sequence numbers distinguish a slow reply from commands lost or reordered in DreamSeeker.
/datum/unit_test/ping_sequence_diagnostics/Run()
	var/list/normal = ping_sequence_observe(4, 5)
	TEST_ASSERT(normal["valid"], "a positive sequence must be accepted")
	TEST_ASSERT_EQUAL(normal["next_received"], 5, "an in-order reply must advance the received sequence")
	TEST_ASSERT_EQUAL(normal["skip"], 0, "an in-order reply must not invent a skipped command")
	TEST_ASSERT(!normal["out_of_order"], "an in-order reply must not be marked reordered")

	var/list/skipped = ping_sequence_observe(5, 8)
	TEST_ASSERT_EQUAL(skipped["skip"], 2, "a sequence gap must preserve the exact number of missing replies")
	TEST_ASSERT_EQUAL(skipped["next_received"], 8, "the high-water mark must advance across a gap")

	var/list/reordered = ping_sequence_observe(8, 7)
	TEST_ASSERT(reordered["out_of_order"], "a late older reply must be marked out of order")
	TEST_ASSERT_EQUAL(reordered["next_received"], 8, "a late older reply must not move the high-water mark backwards")

	var/list/legacy = ping_sequence_observe(8, null)
	TEST_ASSERT(!legacy["valid"], "legacy two-argument ping replies must remain accepted without sequence bookkeeping")
	TEST_ASSERT_EQUAL(legacy["next_received"], 8, "a legacy reply must not change sequence state")

/// Suspects are evidence labels, not a forced single-cause guess.
/datum/unit_test/ping_diagnostic_suspects_preserve_correlations/Run()
	var/list/correlated = ping_diagnostic_suspects(
		CLIENT_LATENCY_SERVER_STALL_WARN_MS,
		CLIENT_RESOURCE_STAGE_REQUESTED,
		1,
		2,
		3,
		2,
		FALSE,
	)
	TEST_ASSERT("server_stall" in correlated, "measured server stall must be retained")
	TEST_ASSERT("slow_client_topic" in correlated, "a recent client Topic must be retained")
	TEST_ASSERT("skin_roundtrip" in correlated, "a recent skin IPC delay must be retained")
	TEST_ASSERT("browser_event_loop_or_bridge" in correlated, "a recent browser delay must be retained")
	TEST_ASSERT("resource_delivery" in correlated, "an unfinished resource pipeline must be retained")
	TEST_ASSERT("client_command_queue" in correlated, "sequence loss must identify the client command queue")

	var/list/uncorrelated = ping_diagnostic_suspects(0, CLIENT_RESOURCE_STAGE_UI_READY, null, null, null)
	TEST_ASSERT_EQUAL(length(uncorrelated), 1, "an unexplained spike must have one conservative fallback")
	TEST_ASSERT("client_or_transport_queue" in uncorrelated, "an unexplained spike must not be mislabeled as a server fault")

/// Keep every end of the diagnostic round trip connected in source.
/datum/unit_test/client_latency_diagnostic_wiring/Run()
	var/server_maint_source = read_source_file("code/controllers/subsystem/server_maint.dm")
	TEST_ASSERT(findtext(server_maint_source, "+\[C.ping_sequence_sent\]"), "native ping commands must carry a sequence number")

	var/statbrowser_source = read_source_file("html/statbrowser/src/latency-diagnostics.js")
	TEST_ASSERT(findtext(statbrowser_source, ".client-latency-report statbrowser_event_loop"), "statbrowser must report event-loop stalls through the hidden verb")

	var/tgui_source = read_source_file("tgui/packages/tgui-panel/ping/middleware.js")
	TEST_ASSERT(findtext(tgui_source, "type: 'pingDiagnostic'"), "tgui-panel must report slow browser-to-DM round trips")

	var/world_topic_source = read_source_file("code/game/world.dm")
	TEST_ASSERT(findtext(world_topic_source, "slow_world_topic"), "inbound BYOND Topic handlers must emit slow-request diagnostics")

	var/blocking_source = read_source_file("modular_bluemoon/code/_HELPERS/blocking_calls.dm")
	TEST_ASSERT(findtext(blocking_source, "blocking_world_export"), "outbound BYOND Topic exports must emit slow-call diagnostics")

	var/logging_source = read_source_file("code/__HELPERS/_logging.dm")
	TEST_ASSERT(findtext(logging_source, "rustg_formatted_timestamp"), "latency JSON must use a precise host timestamp instead of float-quantized world.realtime")

	var/latejoin_source = read_source_file("code/modules/mob/dead/new_player/new_player.dm")
	TEST_ASSERT(findtext(latejoin_source, "slow_latejoin"), "slow SelectedJob handling must emit a nested latejoin profile")
	for(var/required_phase in list("create_character", "equip_rank", "manifest_inject", "arrival_and_preferences"))
		TEST_ASSERT(findtext(latejoin_source, "\"[required_phase]\""), "latejoin profile is missing phase [required_phase]")

	var/job_source = read_source_file("code/controllers/subsystem/job.dm")
	TEST_ASSERT(findtext(job_source, "slow_equip_rank"), "slow latejoin equipment must emit its own nested profile")

	var/map_template_source = read_source_file("code/modules/mapping/map_template.dm")
	TEST_ASSERT(findtext(map_template_source, "map parse"), "runtime DMM parsing must be named in the slow-work ring")
	TEST_ASSERT(findtext(map_template_source, "map model cache"), "runtime DMM model-cache building must be named in the slow-work ring")

	var/weeds_source = read_source_file("code/game/objects/structures/aliens.dm")
	var/node_process_start = findtext(weeds_source, "/obj/structure/alien/weeds/node/process()")
	var/node_process_end = findtext(weeds_source, "#undef NODERANGE", node_process_start)
	var/node_process_source = copytext(weeds_source, node_process_start, node_process_end)
	TEST_ASSERT(findtext(node_process_source, "TICK_CHECK"), "a mature alien weed node must yield through SSobj instead of scanning its whole range in one tick")

	var/tick_spike_source = read_source_file("modular_bluemoon/code/controllers/subsystem/tick_spikes.dm")
	TEST_ASSERT(findtext(tick_spike_source, "build_spike_diagnostic"), "tick-spike reports must include the live SSair phase and queue sizes")
	TEST_ASSERT(findtext(SStick_spikes.build_size_metrics_line(), "SSair: phase"), "the rendered tick-spike size line omitted the SSair diagnostic snapshot")
