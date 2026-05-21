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
/// Server-wide time dilation (percent) at or above this means the server cannot hold
/// real-time: it is the bottleneck, and the rtt/server split becomes unreliable because
/// the tick clock runs slow (server delay leaks into the wall-clock RTT instead).
#define PING_TIDI_SERVER_PCT 10
/// ...unless RTT is this high (ms) and is itself the dominant component, where a genuinely
/// bad personal connection wins regardless of moderate dilation. A server delay that
/// outweighs even a high RTT still reads as server - don't blame the player's network for it.
#define PING_NETWORK_HARD_MS 60
/// A recent RTT peak this far (ms) above the running average is a transient spike. Caught
/// independently of dilation/jitter, which are smoothed and miss short hitches that don't
/// move the average (e.g. a single subsystem overrunning for one fire).
#define PING_SPIKE_MIN_MS 25

/// Classify a single client's ping into one verdict. All inputs are milliseconds
/// (except client_fps and time_dilation, which is a percent). `spike` is the recent RTT
/// peak above the average. Pure: no side effects, no I/O.
/proc/classify_ping(rtt as num, server as num, jitter as num, floor as num, client_fps as num, time_dilation as num, spike as num)
	// High time dilation is the authoritative server-load signal. It also invalidates the
	// rtt/server decomposition (under dilation the tick clock lags real time, so server
	// delay shows up inside RTT, not in `server`). Skip only when RTT is so high that the
	// player's own connection clearly dominates.
	if(time_dilation >= PING_TIDI_SERVER_PCT && rtt < PING_NETWORK_HARD_MS)
		return PING_VERDICT_SERVER
	// Genuinely bad personal connection: an RTT this high that also outweighs the server
	// delay dominates regardless of any transient spike, so it wins ahead of the spike/jitter
	// checks. When the server delay is the larger component we fall through instead - a slow
	// server shouldn't read as a network problem just because the RTT is high.
	if(rtt >= PING_NETWORK_HARD_MS && rtt >= server)
		return PING_VERDICT_NETWORK
	// Transient spike with otherwise-calm averages: a peak well above the mean means
	// instability even when smoothed dilation/jitter look fine. Checked before the soft
	// network threshold so a remote client's steady baseline RTT doesn't mask a real hitch.
	if(spike >= PING_SPIKE_MIN_MS)
		return PING_VERDICT_JITTER
	// Network-bound only when the RTT is significant, outweighs the server delay, and
	// actually exceeds the structural floor. The floor already grows with a low client
	// framerate (longer frames inflate the measured round-trip), so an elevated RTT that
	// stays within floor reach is the framerate's doing - leave it for the client verdict
	// below rather than blaming the network.
	if(rtt >= PING_NETWORK_MIN_MS && rtt >= server && rtt > floor + PING_FLOOR_MARGIN_MS)
		return PING_VERDICT_NETWORK
	var/total = rtt + server
	if(jitter >= PING_JITTER_MIN_MS && total > 0 && (jitter / total) >= PING_JITTER_RATIO)
		return PING_VERDICT_JITTER
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
