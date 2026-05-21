// Ping verdict classification. Pure logic, unit-tested in
// code/modules/unit_tests/ping_diagnostics.dm. Human-readable text lives in the
// TGUI layer (PingDiagnostics.tsx), keyed by these verdict codes.

#define PING_VERDICT_HEALTHY "healthy"
#define PING_VERDICT_SERVER "server"
#define PING_VERDICT_NETWORK "network"
#define PING_VERDICT_JITTER "jitter"
#define PING_VERDICT_CLIENT "client"

/// Server delay this far (ms) above the structural floor counts as real server load.
#define PING_FLOOR_MARGIN_MS 8
/// Network RTT at or above this (ms) is treated as a significant network component.
#define PING_NETWORK_MIN_MS 15
/// Jitter must be at least this many ms before instability is flagged.
#define PING_JITTER_MIN_MS 10
/// ...and jitter must be at least this fraction of the rtt+server combined ping.
#define PING_JITTER_RATIO 0.6
/// Client framerate below this inflates the measured round-trip.
#define PING_CLIENT_FPS_MIN 20
/// Server-wide time dilation (percent) at or above this means the server is struggling to hold
/// real-time and the rtt/server split becomes unreliable (the tick clock runs slow, so server
/// delay leaks into the wall-clock RTT instead of the `server` figure). Below the severe
/// threshold this is only decisive when the player's own connection isn't the dominant cost.
#define PING_TIDI_SERVER_PCT 10
/// At or above this dilation the server is the acute, unambiguous bottleneck for everyone on it,
/// so it is the verdict regardless of how far the player sits from the server.
#define PING_TIDI_SEVERE_PCT 30
/// Under merely moderate dilation, an RTT this high (ms) that also outweighs the server delay
/// means the player's own connection - not the moderate server wobble - dominates their ping,
/// so it reads as network. Scoped to the dilation escape only; it does NOT gate the general
/// network verdict (a stable 300ms link is judged the same way as a stable 40ms one).
#define PING_NETWORK_HARD_MS 60
/// A recent RTT peak must be at least this many ms above the running average to count as a
/// transient spike. Absolute floor so tiny absolute hitches on a low-ping link are ignored.
#define PING_SPIKE_MIN_MS 25
/// ...and the peak must also be at least this fraction of the player's own baseline RTT, so a
/// peak that is large in absolute terms but routine for a high-latency link (e.g. +30ms on a
/// 300ms connection) is not mistaken for instability, while the same +30ms on a 40ms link is.
#define PING_SPIKE_RATIO 0.25

/// Classify a single client's ping into one verdict. All inputs are milliseconds
/// (except client_fps and time_dilation, which is a percent). `spike` is the recent RTT
/// peak above the average. Pure: no side effects, no I/O.
///
/// Order matters: server overload (dilation) is authoritative first because it invalidates the
/// rtt/server decomposition; instability (spike/jitter) is checked next so a high but steady
/// baseline RTT cannot mask a real hitch; only then do we conclude the ping is plain network
/// distance. This keeps the verdict meaningful across the whole latency range - a stable 40ms
/// and a stable 300ms player both read as a calm "network", while either one bouncing reads as
/// "jitter".
/proc/classify_ping(rtt as num, server as num, jitter as num, floor as num, client_fps as num, time_dilation as num, spike as num)
	// Severe dilation: the server cannot hold real-time, which dominates everyone's experience
	// regardless of their distance from it. Authoritative.
	if(time_dilation >= PING_TIDI_SEVERE_PCT)
		return PING_VERDICT_SERVER
	// Moderate dilation: the server is the cause unless the player's own connection clearly
	// dominates the (modest) server-induced delay - a genuinely far/bad personal connection
	// shouldn't be blamed on a server that is only mildly behind.
	if(time_dilation >= PING_TIDI_SERVER_PCT && rtt < PING_NETWORK_HARD_MS)
		return PING_VERDICT_SERVER
	// Transient spike: a peak well above the player's own baseline, gauged both absolutely and
	// proportionally so it scales with the connection. Checked before the network conclusion so
	// a steady high baseline (a far player) doesn't shadow a real hitch on top of it.
	if(spike >= PING_SPIKE_MIN_MS && spike >= rtt * PING_SPIKE_RATIO)
		return PING_VERDICT_JITTER
	var/total = rtt + server
	// Sustained jitter: instability that the smoothed average misses. The ratio test is already
	// scale-relative, so it behaves the same at any baseline.
	if(jitter >= PING_JITTER_MIN_MS && total > 0 && (jitter / total) >= PING_JITTER_RATIO)
		return PING_VERDICT_JITTER
	// Network-bound: a significant, stable RTT that outweighs the server delay and clears the
	// structural floor. The floor grows with a low client framerate, so an elevated RTT that
	// stays within floor reach is the framerate's doing - left for the client verdict below.
	if(rtt >= PING_NETWORK_MIN_MS && rtt >= server && rtt > floor + PING_FLOOR_MARGIN_MS)
		return PING_VERDICT_NETWORK
	// Residual server load that isn't reflected as dilation (e.g. one slow subsystem).
	if(server > floor + PING_FLOOR_MARGIN_MS)
		return PING_VERDICT_SERVER
	if(client_fps && client_fps < PING_CLIENT_FPS_MIN)
		return PING_VERDICT_CLIENT
	return PING_VERDICT_HEALTHY

/// Estimate the irreducible round-trip floor (ms): half a server tick plus half a
/// client frame. Heuristic; the constants above are tunable against observed behavior.
/proc/estimate_ping_floor(client_fps)
	var/server_tick_ms = world.tick_lag * 100
	var/client_frame_ms = client_fps ? (1000 / client_fps) : 0
	return round((server_tick_ms + client_frame_ms) * 0.5, 0.1)
