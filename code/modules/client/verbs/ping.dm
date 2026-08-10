#define PING_RTT_WINDOW_SIZE 15

/// Renders a timestamp for the `.update_ping` / `.display_ping` command line.
/// Both stamps leave as text and come back as numbers, so whatever this drops is lost
/// for good and lands in the measured round trip as pure error. Plain interpolation
/// keeps six significant digits, and REALTIMEOFDAY needs all six for its integer part
/// alone from 02:47 GMT until midnight - that rounded every send stamp to a whole
/// decisecond and put up to 50ms of noise into every sample. world.time hits the same
/// wall three hours into a round. Twelve digits round-trip a 32-bit float exactly.
#define PING_WIRE_PRECISION 12

/proc/ping_wire_num(value)
	return num2text(value, PING_WIRE_PRECISION)

/**
 * Gap between two neighbouring 32-bit floats at `value`'s magnitude, in ms.
 *
 * REALTIMEOFDAY is stored as a 32-bit float, so its own resolution decays through the day:
 * the step is 3.125ms from 07:16 GMT and 6.25ms from 14:33 GMT to midnight. A difference of
 * two such stamps is always a whole multiple of that step, so a genuine 1ms round trip is
 * reported as one entire step - that is the 6.25 / 12.5 / 18.75 ladder that fills the ping
 * logs on a loopback connection. world.time carries five binades less: its step is 0.195ms
 * half an hour into a round and still only 0.78ms three hours in, which makes the tick clock
 * the finer of the two instruments and the wall clock worth believing only above its step.
 */
/proc/ping_realtime_step_ms(value)
	value = abs(value)
	if(value < 1)
		return 0
	return 100 / (2 ** (23 - round(log(2, value))))

/// Server-side share of a round trip, in ms: the wall clock always covers at least as
/// much ground as the game clock, and the gap is time the server spent stalled rather
/// than time the sample spent in transit. `step_ms` is the wall clock's own resolution - a
/// gap narrower than one step is the rounding described above and not a stall, and booking
/// it as server time put a phantom 1-5ms into every fourth sample of an idle local round.
/proc/ping_server_component(rtt_ms, tick_ms, step_ms = 0)
	return max(rtt_ms - tick_ms - step_ms, 0)

/// The round trip a sample is worth. The tick clock is the base because it resolves three
/// orders of magnitude finer; the wall clock only adds what it can prove, which is real
/// time the game clock never booked at all.
/proc/ping_best_roundtrip(tick_ms, rtt_ms, step_ms = 0)
	return max(tick_ms, 0) + ping_server_component(rtt_ms, tick_ms, step_ms)

/// Jitter is a distance between two samples, so the first sample of a connection has none.
/// Seeding it with `abs(ping - 0)` published the whole first round trip as jitter, and on a
/// connection whose first samples are taken during resource delivery the fast average then
/// carried a four-digit number for the next half minute.
/proc/ping_jitter_sample(rtt_ms, previous_rtt_ms, has_previous)
	if(!has_previous)
		return 0
	return abs(rtt_ms - previous_rtt_ms)

/// Player-facing average follows the already filtered rolling median. Raw RTT keeps
/// its own slow EMA for diagnostics, but must not pin the UI to a login outlier for a
/// minute after the native channel recovered. Crossing UI_READY is a hard reset:
/// every earlier sample was taken while DreamSeeker was still loading its interface.
/proc/ping_display_average(previous_average, stable_ping, resource_became_ready = FALSE)
	if(isnull(previous_average) || resource_became_ready)
		return stable_ping
	return MC_AVERAGE_FAST(previous_average, stable_ping)

/// Pure sequence bookkeeping kept outside /client so regressions can exercise it.
/proc/ping_sequence_observe(last_received, sequence)
	var/list/result = list(
		"valid" = FALSE,
		"next_received" = last_received,
		"skip" = 0,
		"out_of_order" = FALSE,
	)
	if(!isnum(sequence))
		return result
	sequence = round(sequence)
	if(sequence <= 0)
		return result
	result["valid"] = TRUE
	if(sequence <= last_received)
		result["out_of_order"] = TRUE
		return result
	result["skip"] = max(sequence - last_received - 1, 0)
	result["next_received"] = sequence
	return result

/**
 * Produces deliberately conservative suspects for a native ping spike.
 * Multiple causes are retained: e.g. a slow Topic during resource delivery is
 * more useful than forcing the event into one guessed bucket.
 */
/proc/ping_diagnostic_suspects(server_ms, resource_stage, skin_age_ds, topic_age_ds, browser_age_ds, sequence_skip = 0, out_of_order = FALSE, reply_tick_usage = 0)
	var/list/suspects = list()
	if(server_ms >= CLIENT_LATENCY_SERVER_STALL_WARN_MS)
		suspects += "server_stall"
	// The reply landed on a tick the MC had already spent. DreamDaemon cannot run the verb
	// while DM is executing, so the sample carried the tail of that tick and nothing else -
	// a class of delay `server_ms` is structurally blind to, because the tick clock counts
	// TICK_USAGE_REAL and therefore grows in lockstep with the wall clock during an
	// over-budget tick. Without this label those spikes fell through to the transport.
	if(reply_tick_usage >= CLIENT_LATENCY_MC_TAIL_TICK_USAGE)
		suspects += "mc_tick_tail"
	if(isnum(topic_age_ds) && topic_age_ds <= CLIENT_LATENCY_CORRELATION_WINDOW)
		suspects += "slow_client_topic"
	if(isnum(skin_age_ds) && skin_age_ds <= CLIENT_LATENCY_CORRELATION_WINDOW)
		suspects += "skin_roundtrip"
	if(isnum(browser_age_ds) && browser_age_ds <= CLIENT_LATENCY_CORRELATION_WINDOW)
		suspects += "browser_event_loop_or_bridge"
	if(resource_stage < CLIENT_RESOURCE_STAGE_UI_READY)
		suspects += "resource_delivery"
	if(sequence_skip || out_of_order)
		suspects += "client_command_queue"
	if(!length(suspects))
		suspects += "client_or_transport_queue"
	return suspects

/// Pushes a sample into a FIFO window while incrementally maintaining its sorted mirror.
/// Returns the median of the window. Replaces a full copy+TimSort per sample.
/proc/rtt_window_push(list/window, list/sorted, value, max_size)
	// evict oldest samples first so the new one always fits
	while(length(window) >= max_size)
		var/oldest = window[1]
		window.Cut(1, 2)
		var/oldest_index = sorted.Find(oldest)
		if(oldest_index)
			sorted.Cut(oldest_index, oldest_index + 1)
	window += value
	// binary search for the insertion position in the sorted mirror
	var/low = 1
	var/high = length(sorted) + 1
	while(low < high)
		var/mid = (low + high) >> 1
		if(sorted[mid] < value)
			low = mid + 1
		else
			high = mid
	sorted.Insert(low, value)
	if(length(sorted) != length(window)) // desync (window mutated externally) - rebuild the mirror
		sorted.Cut()
		sorted += window
		sortTim(sorted, GLOBAL_PROC_REF(cmp_numeric_asc))
	return sorted[max(1, CEILING(length(sorted) * 0.5, 1))]

/client/proc/current_ping_tickstamp()
	return world.time + world.tick_lag * TICK_USAGE_REAL / 100

/client/proc/pingfromtickstamp(tickstamp)
	return (current_ping_tickstamp() - tickstamp) * 100

/client/proc/pingfromrealtime(sent_realtime)
	return max((REALTIMEOFDAY - sent_realtime) * 100, 0)

/client/proc/stabilize_rtt_ping(raw_rtt_ping)
	raw_rtt_ping = max(raw_rtt_ping, 0)
	if(!islist(ping_rtt_window))
		ping_rtt_window = list()
	if(!islist(ping_rtt_sorted))
		ping_rtt_sorted = list()
	return rtt_window_push(ping_rtt_window, ping_rtt_sorted, raw_rtt_ping, PING_RTT_WINDOW_SIZE)

/// Called only for skin IPC which already exceeded the slow-work threshold.
/client/proc/record_skin_latency(kind, detail, cost_ms, started_world)
	last_skin_latency_at = world.time
	last_skin_latency_kind = kind
	last_skin_latency_ms = cost_ms
	last_skin_latency_detail = detail
	log_client_latency("skin_roundtrip", src, list(
		"kind" = kind,
		"detail" = detail,
		"latency_ms" = cost_ms,
		"started_world_time" = started_world,
		"world_elapsed_ds" = isnull(started_world) ? null : max(world.time - started_world, 0),
	))

/// Mirrors record_slow_topic into the latency timeline for cross-event correlation.
/client/proc/record_topic_latency(context, href_preview, cost_ms)
	last_slow_topic_at = world.time
	last_slow_topic_context = context
	last_slow_topic_ms = cost_ms
	log_client_latency("slow_client_topic", src, list(
		"context" = context,
		"href" = href_preview,
		"latency_ms" = cost_ms,
	))

/**
 * Accepts independent latency reports from statbrowser and tgui-panel.
 * Browser data is untrusted, so sources, bounds and per-source rate are checked.
 */
/client/proc/record_browser_latency(source, latency_ms, hidden, focused)
	if(!(source in list("statbrowser_event_loop", "tgui_bridge")))
		return FALSE
	if(!isnum(latency_ms) || latency_ms < CLIENT_LATENCY_BROWSER_WARN_MS || latency_ms > 300000)
		return FALSE
	var/last_report_at = browser_latency_report_times[source]
	if(!isnull(last_report_at) && world.time - last_report_at < CLIENT_LATENCY_BROWSER_REPORT_COOLDOWN)
		return FALSE
	browser_latency_report_times[source] = world.time

	latency_ms = round(latency_ms, 0.1)
	last_browser_latency_at = world.time
	last_browser_latency_source = source
	last_browser_latency_ms = latency_ms
	last_browser_latency_hidden = !!hidden
	last_browser_latency_focused = !!focused
	SStime_track?.record_browser_latency(latency_ms)
	log_client_latency("browser_latency", src, list(
		"source" = source,
		"latency_ms" = latency_ms,
		"document_hidden" = !!hidden,
		"document_focused" = !!focused,
	))
	return TRUE

/client/verb/client_latency_report(source as text, latency_ms as num, hidden as num, focused as num)
	set instant = TRUE
	set hidden = TRUE
	set name = ".client-latency-report"
	record_browser_latency(source, latency_ms, hidden, focused)

/client/verb/update_ping(tickstamp as num, sent_realtime as null|num, sequence as null|num)
	set instant = TRUE
	set name = ".update_ping"

	// Read before this verb does anything of its own: it is the MC's state at the instant
	// DreamDaemon got round to the reply, and that instant is what the sample measures.
	var/reply_tick_usage = TICK_USAGE

	// Helper procs are inlined here: this verb runs roughly once per 2 seconds per client.
	var/tick_ping = (world.time + world.tick_lag * TICK_USAGE_REAL / 100 - tickstamp) * 100
	var/reply_realtime = REALTIMEOFDAY
	var/realtime_step = 0
	var/rtt_ping_raw
	if(isnum(sent_realtime))
		rtt_ping_raw = max((reply_realtime - sent_realtime) * 100, 0)
		realtime_step = ping_realtime_step_ms(reply_realtime)
	else
		// Backward compatibility with one-argument invocations.
		rtt_ping_raw = tick_ping

	// The tick clock leads and the wall clock only tops it up past its own resolution: the
	// wall clock cannot resolve a local round trip at all, and taking it at face value
	// snapped every sample up to a whole 6.25ms step.
	var/server_ping = ping_server_component(rtt_ping_raw, tick_ping, realtime_step)
	var/best_ping = ping_best_roundtrip(tick_ping, rtt_ping_raw, realtime_step)

	var/previous_rtt = ping_replies_received ? lastping_rtt_raw : null
	var/reply_gap_ms = lastping_realtimeofday ? max((reply_realtime - lastping_realtimeofday) * 100, 0) : null
	var/list/sequence_result = ping_sequence_observe(ping_sequence_received, sequence)
	if(sequence_result["valid"])
		ping_sequence_received = sequence_result["next_received"]

	var/rtt_ping = stabilize_rtt_ping(best_ping)

	var/jitter = ping_jitter_sample(best_ping, lastping_rtt_raw, ping_replies_received > 0)
	ping_replies_received++
	if(isnull(avgping_jitter))
		avgping_jitter = jitter
	else
		avgping_jitter = MC_AVERAGE_FAST(avgping_jitter, jitter)

	lastping_tick = tick_ping
	lastping_rtt = rtt_ping
	lastping_rtt_raw = best_ping
	lastping_server = server_ping
	lastping = rtt_ping
	lastping_realtimeofday = reply_realtime
	// Отметка свежести: у подвисшего клиента значения остаются на месте навсегда, и сводка
	// по миру (SStime_track) залипала на его максимуме до конца раунда.
	lastping_at = world.time
	ping_updated = TRUE
	// Ответ на пинг доказывает, что скин round-trip'ится нормально. Только вместе с
	// поднятым статбраузером - иначе первый же пинг объявил бы интерфейс готовым у
	// клиента, у которого он так и не загрузился.
	var/resource_became_ready = statbrowser_ready && resource_stage < CLIENT_RESOURCE_STAGE_UI_READY
	if(statbrowser_ready)
		advance_resource_stage(CLIENT_RESOURCE_STAGE_UI_READY)

	avgping_rtt = ping_display_average(avgping_rtt, rtt_ping, resource_became_ready)

	if(isnull(avgping_rtt_raw))
		avgping_rtt_raw = best_ping
	else
		avgping_rtt_raw = MC_AVERAGE_SLOW(avgping_rtt_raw, best_ping)

	if(isnull(avgping_server))
		avgping_server = server_ping
	else
		avgping_server = MC_AVERAGE_SLOW(avgping_server, server_ping)

	// Keep the legacy fields as the player-facing RTT value.
	avgping = avgping_rtt

	var/sequence_skip = sequence_result["skip"]
	var/sequence_out_of_order = sequence_result["out_of_order"]
	SStime_track?.record_ping_reply(best_ping, tick_ping, server_ping, sequence_skip, sequence_out_of_order)
	var/is_noteworthy = best_ping >= CLIENT_LATENCY_RTT_WARN_MS || server_ping >= CLIENT_LATENCY_SERVER_STALL_WARN_MS || sequence_skip || sequence_out_of_order
	var/can_report = isnull(last_ping_latency_report_at) || world.time - last_ping_latency_report_at >= CLIENT_LATENCY_NATIVE_REPORT_COOLDOWN
	if(is_noteworthy && can_report)
		last_ping_latency_report_at = world.time
		var/skin_age = last_skin_latency_at ? max(world.time - last_skin_latency_at, 0) : null
		var/topic_age = last_slow_topic_at ? max(world.time - last_slow_topic_at, 0) : null
		var/browser_age = last_browser_latency_at ? max(world.time - last_browser_latency_at, 0) : null
		var/list/suspects = ping_diagnostic_suspects(server_ping, resource_stage, skin_age, topic_age, browser_age, sequence_skip, sequence_out_of_order, reply_tick_usage)
		log_client_latency("native_ping_spike", src, list(
			"sequence" = sequence_result["valid"] ? round(sequence) : null,
			"sequence_sent" = ping_sequence_sent,
			"sequence_received" = ping_sequence_received,
			"sequence_skip" = sequence_skip,
			"sequence_out_of_order" = !!sequence_out_of_order,
			"rtt_ms" = best_ping,
			"stable_median_ms" = rtt_ping,
			"display_average_ms" = avgping_rtt,
			"tick_clock_ms" = tick_ping,
			"server_stall_ms" = server_ping,
			"reply_tick_usage" = reply_tick_usage,
			"realtime_step_ms" = realtime_step,
			"nonstall_roundtrip_ms" = max(best_ping - server_ping, 0),
			"previous_rtt_ms" = previous_rtt,
			"reply_gap_ms" = reply_gap_ms,
			"sent_tickstamp" = tickstamp,
			"sent_realtime_ds" = sent_realtime,
			"suspects" = suspects,
		))

/client/verb/display_ping(tickstamp as num, sent_realtime as null|num)
	set instant = TRUE
	set name = ".display_ping"

	var/tick_ping = pingfromtickstamp(tickstamp)
	var/rtt_ping_raw = tick_ping
	var/realtime_step = 0
	if(isnum(sent_realtime))
		// Backward compatibility with one-argument invocations keeps the tick clock alone.
		rtt_ping_raw = pingfromrealtime(sent_realtime)
		realtime_step = ping_realtime_step_ms(REALTIMEOFDAY)
	var/rtt_ping = lastping_rtt ? lastping_rtt : ping_best_roundtrip(tick_ping, rtt_ping_raw, realtime_step)
	to_chat(src, "<span class='notice'>Round trip ping took [round(rtt_ping, 1)]ms (Stable Avg: [round(avgping, 1)]ms)</span>")

/client/verb/ping()
	set name = "Ping"
	set category = "OOC"
	winset(src, null, "command=.display_ping+[ping_wire_num(current_ping_tickstamp())]+[ping_wire_num(REALTIMEOFDAY)]")

#undef PING_RTT_WINDOW_SIZE
#undef PING_WIRE_PRECISION
