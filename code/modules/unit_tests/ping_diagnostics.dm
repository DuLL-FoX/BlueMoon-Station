/// Verifies classify_ping() returns the correct verdict for each component profile.
/// String literals mirror the PING_VERDICT_* macros (kept literal here because the
/// macros are defined in modular_bluemoon, included after this test in the .dme).
/datum/unit_test/ping_classify/Run()
	// Args: rtt, server, jitter, floor, client_fps, time_dilation (percent), spike (ms peak
	// above average). dilation 0 = server holding real-time; spike 0 = steady.
	// Healthy: localhost-style, server delay near the floor, no dilation, no spike.
	TEST_ASSERT_EQUAL(classify_ping(0, 5, 2, 10, 60, 0, 0), "healthy", "low everything should be healthy")
	// Server-bound: server delay well above floor + margin.
	TEST_ASSERT_EQUAL(classify_ping(1, 30, 3, 10, 60, 0, 0), "server", "high server delay should be server-bound")
	// Network-bound: RTT dominant and significant, server keeping up.
	TEST_ASSERT_EQUAL(classify_ping(40, 5, 2, 10, 60, 0, 0), "network", "high RTT should be network-bound")
	// Jitter-bound: jitter large relative to total.
	TEST_ASSERT_EQUAL(classify_ping(5, 5, 20, 10, 60, 0, 0), "jitter", "high jitter share should be jitter-bound")
	// Client-bound: low framerate inflates round-trip, nothing else elevated.
	TEST_ASSERT_EQUAL(classify_ping(2, 6, 1, 10, 10, 0, 0), "client", "low client fps should be client-bound")
	// Dilation-bound: localhost case where the tick is congested. The rtt/server split
	// reads as "network" (server=0.7) but high dilation means the server is the cause.
	TEST_ASSERT_EQUAL(classify_ping(45.7, 0.7, 15.8, 29, 60, 20.7, 0), "server", "high time dilation should be server-bound")
	// Escape hatch: a genuinely bad personal connection still reads as network even when
	// the server is somewhat dilated.
	TEST_ASSERT_EQUAL(classify_ping(150, 5, 2, 10, 60, 12, 0), "network", "extreme RTT dominates over moderate dilation")
	// Spike-bound: averages are calm (dilation < 1%, low jitter) but a recent peak is far
	// above the mean - a transient hitch the smoothed metrics miss.
	TEST_ASSERT_EQUAL(classify_ping(10, 5, 3, 29, 60, 0.5, 40), "jitter", "a spike above average should flag instability even at low dilation")
	// Spike on a remote client: a steady baseline RTT above the network threshold must not
	// shadow a large transient peak - the spike still wins ahead of the soft network verdict.
	TEST_ASSERT_EQUAL(classify_ping(40, 5, 3, 29, 60, 0.5, 80), "jitter", "a spike should win over the soft network threshold for a remote client")
	// Low framerate inflates both the RTT and the structural floor: a moderate RTT that stays
	// within reach of the (inflated) floor is the framerate's doing, not the network.
	TEST_ASSERT_EQUAL(classify_ping(40, 5, 2, 75, 10, 0, 0), "client", "an elevated rtt explained by the low-fps floor should be client-bound, not network")
	// Server delay dominates an already-high RTT: the server is the bottleneck even past the
	// hard RTT threshold, so don't surface it as a network problem.
	TEST_ASSERT_EQUAL(classify_ping(80, 120, 3, 10, 60, 0, 0), "server", "server delay outweighing a high rtt should be server-bound, not network")
