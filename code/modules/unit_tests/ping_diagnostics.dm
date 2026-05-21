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

	// --- Latency-range matrix: the verdict must stay meaningful whether a player sits at ~40ms
	// or ~300ms. A stable connection at either end is plain network distance, not a warning, and
	// instability at either end is flagged - judged proportionally so it scales with the link.
	// Stable low-ping player: a calm 40ms link is network distance, not a problem in itself.
	TEST_ASSERT_EQUAL(classify_ping(40, 5, 2, 14, 60, 0, 0), "network", "a stable 40ms link reads as network distance")
	// Stable high-ping player: a calm 300ms link is still just distance, not instability.
	TEST_ASSERT_EQUAL(classify_ping(300, 5, 2, 14, 60, 0, 0), "network", "a stable 300ms link reads as network distance, not a problem")
	// High-ping player with a real transient peak: +120ms over a 300ms baseline is instability.
	TEST_ASSERT_EQUAL(classify_ping(300, 5, 2, 14, 60, 0, 120), "jitter", "a large transient peak on a high baseline flags as jitter")
	// High-ping player with routine wobble: +40ms over 300ms clears the absolute spike floor but
	// not the proportional one (300 * 0.25 = 75), so it must not false-flag as jitter.
	TEST_ASSERT_EQUAL(classify_ping(300, 5, 2, 14, 60, 0, 40), "network", "proportionally small wobble on a high baseline stays network")
	// Low-ping player with the same +40ms peak: proportionally large on a 40ms link, so it flags.
	TEST_ASSERT_EQUAL(classify_ping(40, 5, 2, 14, 60, 0, 40), "jitter", "the same peak on a low baseline is proportionally large and flags as jitter")
	// Severe dilation makes the server the verdict even for a far 300ms player.
	TEST_ASSERT_EQUAL(classify_ping(300, 5, 2, 14, 60, 35, 0), "server", "severe dilation is server-bound even for a high-ping player")
	// Moderate dilation with a far player: their 300ms connection dominates the mild server
	// wobble, so it stays network rather than blaming the server.
	TEST_ASSERT_EQUAL(classify_ping(300, 5, 2, 14, 60, 15, 0), "network", "moderate dilation does not override a dominant personal connection")
	// Moderate dilation with a near player: 40ms is below the escape, so the server wins.
	TEST_ASSERT_EQUAL(classify_ping(40, 5, 2, 14, 60, 15, 0), "server", "moderate dilation is server-bound when the connection isn't dominant")
