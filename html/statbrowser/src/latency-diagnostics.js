// Lightweight WebView event-loop watchdog. It sends nothing during normal play;
// only a >=100ms scheduling gap crosses the BYOND bridge, at most once per 10s.
// This lets client_latency.jsonl distinguish a busy statbrowser/WebView from a
// native DreamSeeker command-queue delay without polling winget from the server.
var CLIENT_LATENCY_WATCH_INTERVAL_MS = 1000;
var CLIENT_LATENCY_WATCH_THRESHOLD_MS = 100;
var CLIENT_LATENCY_WATCH_REPORT_COOLDOWN_MS = 10000;

function client_latency_now() {
	if (window.performance && typeof window.performance.now === "function") {
		return window.performance.now();
	}
	return Date.now();
}

function start_client_latency_watchdog() {
	var lastTickAt = client_latency_now();
	var lastReportAt = -CLIENT_LATENCY_WATCH_REPORT_COOLDOWN_MS;
	setInterval(function() {
		var now = client_latency_now();
		var drift = Math.max(0, now - lastTickAt - CLIENT_LATENCY_WATCH_INTERVAL_MS);
		lastTickAt = now;
		if (drift < CLIENT_LATENCY_WATCH_THRESHOLD_MS ||
			now - lastReportAt < CLIENT_LATENCY_WATCH_REPORT_COOLDOWN_MS) {
			return;
		}
		lastReportAt = now;
		var hidden = document.hidden ? 1 : 0;
		var focused = typeof document.hasFocus === "function" && document.hasFocus() ? 1 : 0;
		send_byond_command(".client-latency-report statbrowser_event_loop " +
			Math.round(drift) + " " + hidden + " " + focused);
	}, CLIENT_LATENCY_WATCH_INTERVAL_MS);
}
