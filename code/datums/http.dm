#define HTTP_DEFAULT_TIMEOUT 30 SECONDS
#define TGS_HTTP_TIMEOUT 30 SECONDS

/**
 * One-shot rust-g HTTP request.
 *
 * rust-g stores every async request in a native job map until DM consumes the
 * result through http_check_request(). Requests therefore may not be reused and
 * callers which stop waiting must let drain_async() consume the eventual result.
 */
/datum/http_request
	var/id
	var/started = FALSE
	var/in_progress = FALSE
	var/completed = FALSE

	var/method
	var/body
	var/headers
	var/url
	/// If present response body will be saved to this file.
	var/output_file
	/// Native request timeout forwarded to rust-g, in seconds.
	var/timeout_seconds

	var/_raw_response

/datum/http_request/proc/prepare(method, url, body = "", list/headers, output_file, timeout_seconds)
	if(started)
		CRASH("Attempted to prepare an HTTP request which has already started.")

	if(!length(headers))
		headers = ""
	else
		headers = json_encode(headers)

	src.method = method
	src.url = url
	src.body = body
	src.headers = headers
	src.output_file = output_file
	src.timeout_seconds = timeout_seconds

/// Submit a request without creating a rust-g job. Only use when no response is needed.
/datum/http_request/proc/fire_and_forget()
	if(started)
		CRASH("Attempted to re-use an HTTP request object.")
	started = TRUE
	completed = TRUE

	var/result = rustg_http_request_fire_and_forget(method, url, body, headers, build_options())
	if(result == "ok")
		return TRUE

	stack_trace("Failed to submit fire-and-forget HTTP request: [result]")
	return FALSE

/**
 * Execute on DreamDaemon's main thread. Kept for exceptional startup/tooling use;
 * live game code should use execute_async() or world_safe_http_request().
 */
/datum/http_request/proc/execute_blocking()
	if(started)
		CRASH("Attempted to re-use an HTTP request object.")
	started = TRUE
	_raw_response = rustg_http_request_blocking(method, url, body, headers, build_options())
	completed = TRUE

/// Start an async rust-g job. Returns FALSE when rust-g rejected the submission.
/datum/http_request/proc/begin_async()
	if(started)
		CRASH("Attempted to re-use an HTTP request object.")
	started = TRUE

	id = rustg_http_request_async(method, url, body, headers, build_options())
	if(isnull(text2num(id)))
		_raw_response = "Proc error: [id]"
		completed = TRUE
		stack_trace(_raw_response)
		return FALSE

	in_progress = TRUE
	return TRUE

/datum/http_request/proc/build_options()
	return json_encode(list(
		"output_filename" = output_file ? output_file : null,
		"body_filename" = null,
		"timeout_seconds" = timeout_seconds > 0 ? timeout_seconds : null,
	))

/datum/http_request/proc/is_complete()
	if(!started)
		return FALSE
	if(completed)
		return TRUE
	if(!in_progress)
		return FALSE

	var/response = rustg_http_check_request(id)
	if(response == RUSTG_JOB_NO_RESULTS_YET)
		return FALSE

	_raw_response = response
	in_progress = FALSE
	completed = TRUE
	return TRUE

/**
 * Wait for an already-started async request without blocking the world.
 * Returns null after the outer DM deadline and drains the native job in a
 * detached proc so rust-g can remove it from its job map.
 */
/datum/http_request/proc/await_response(timeout = HTTP_DEFAULT_TIMEOUT)
	if(!started)
		CRASH("Attempted to await an HTTP request which has not started.")
	if(completed)
		return into_response()

	var/deadline = world.time + max(timeout, 1)
	while(!is_complete())
		if(world.time >= deadline)
			drain_async()
			return null
		stoplag()
	return into_response()

/// Start and await an async request. The request remains strictly one-shot.
/datum/http_request/proc/execute_async(timeout = HTTP_DEFAULT_TIMEOUT)
	begin_async()
	return await_response(timeout)

/// Finish polling an abandoned async request so rust-g can remove its native job.
/datum/http_request/proc/drain_async()
	set waitfor = FALSE
	while(in_progress && !is_complete())
		stoplag()

/**
 * Extract an HTTP status from rust-g 6.x's ureq status-error string.
 *
 * ureq 2.x represents every HTTP 4xx/5xx as Error::Status. rust-g 6.2 stringifies
 * that error instead of serializing the response JSON, so the body and headers are
 * unavailable but the status itself is still authoritative. Keep the match anchored
 * to the end: a URL containing the words "status code" must not spoof a response.
 */
/proc/http_status_from_rustg_error(raw_response)
	if(!istext(raw_response))
		return null
	var/static/regex/status_error = regex(@"status code (\d{3})( \(redirected from .+\))?$")
	if(!status_error.Find(raw_response))
		return null
	var/status = text2num(status_error.group[1])
	if(status < 100 || status > 599)
		return null
	return status

/datum/http_request/proc/into_response() as /datum/http_response
	var/datum/http_response/response = new()
	if(!completed)
		response.errored = TRUE
		response.error = "HTTP response requested before completion"
		return response

	try
		var/list/response_data = json_decode(_raw_response)
		if(!islist(response_data))
			throw EXCEPTION("rust-g returned non-object JSON")

		var/status_code = response_data["status_code"]
		var/response_headers = response_data["headers"]
		var/response_body = response_data["body"]
		if(!isnum(status_code) || status_code < 100 || status_code > 599)
			throw EXCEPTION("rust-g returned an invalid HTTP status")
		if(!isnull(response_headers) && !islist(response_headers))
			throw EXCEPTION("rust-g returned invalid HTTP headers")
		if(!isnull(response_body) && !istext(response_body))
			throw EXCEPTION("rust-g returned an invalid HTTP body")

		response.status_code = status_code
		response.headers = response_headers
		response.body = response_body
	catch
		var/status_code = http_status_from_rustg_error(_raw_response)
		if(status_code)
			response.status_code = status_code
			response.status_only = TRUE
		else
			response.errored = TRUE
			response.error = _raw_response

	return response

/datum/http_response
	var/status_code
	var/body
	var/list/headers
	/// TRUE when rust-g exposed a 4xx/5xx status but ureq discarded its body and headers.
	var/status_only = FALSE

	var/errored = FALSE
	var/error

/datum/http_response/serialize_list(list/options, list/semvers)
	. = ..()
	.["status_code"] = status_code
	.["body"] = body
	.["headers"] = headers
	.["status_only"] = status_only
	.["errored"] = errored
	.["error"] = error
	return .

/// Decode an expected JSON object/array without letting a remote malformed body runtime DM.
/proc/safe_json_decode_list(encoded_json)
	if(!istext(encoded_json) || !rustg_json_is_valid(encoded_json))
		return null
	var/decoded = json_decode(encoded_json)
	return islist(decoded) ? decoded : null

/**
 * Safe replacement for world.Export("http://..."). rust-g performs the request on
 * its worker pool; only this proc sleeps while polling, so DreamDaemon keeps ticking.
 * Both rust-g and DM receive the deadline: the former bounds native work, the latter
 * bounds the caller and drains a late result. Returns null on the outer deadline.
 */
/proc/world_safe_http_request(method, url, body = "", list/headers, output_file, timeout = HTTP_DEFAULT_TIMEOUT)
	timeout = max(timeout, 1)
	var/datum/http_request/request = new()
	var/request_timeout_seconds = max(1, CEILING(timeout / (1 SECONDS), 1))
	request.prepare(method, url, body, headers, output_file, request_timeout_seconds)
	return request.execute_async(timeout)

/// GET convenience wrapper around world_safe_http_request().
/proc/world_safe_http_get(url, timeout = HTTP_DEFAULT_TIMEOUT)
	return world_safe_http_request(RUSTG_HTTP_METHOD_GET, url, timeout = timeout)

/// True fire-and-forget GET: rust-g creates no pollable job, so no native job can leak.
/proc/world_safe_http_get_async(url, timeout = HTTP_DEFAULT_TIMEOUT)
	var/datum/http_request/request = new()
	var/request_timeout_seconds = max(1, CEILING(max(timeout, 1) / (1 SECONDS), 1))
	request.prepare(RUSTG_HTTP_METHOD_GET, url, timeout_seconds = request_timeout_seconds)
	return request.fire_and_forget()

/**
 * TGS v5 talks HTTP to its loopback bridge. The bundled default uses world.Export()
 * and freezes the whole world; this handler satisfies TGS's sleeping-handler contract
 * through rust-g instead.
 */
/datum/tgs_http_handler/rustg/PerformGet(url)
	var/datum/http_response/response = world_safe_http_get(url, TGS_HTTP_TIMEOUT)
	if(isnull(response))
		log_world("TGS rust-g HTTP bridge timed out after [DisplayTimeText(TGS_HTTP_TIMEOUT)].")
		return new /datum/tgs_http_result(null, FALSE)
	if(response.errored)
		log_world("TGS rust-g HTTP bridge failed: [response.error]")
		return new /datum/tgs_http_result(null, FALSE)
	if(response.status_code < 200 || response.status_code >= 300)
		log_world("TGS rust-g HTTP bridge returned status [response.status_code].")
		return new /datum/tgs_http_result(response.body, FALSE)
	if(!istext(response.body))
		log_world("TGS rust-g HTTP bridge returned no response body.")
		return new /datum/tgs_http_result(null, FALSE)
	if(isnull(safe_json_decode_list(response.body)))
		log_world("TGS rust-g HTTP bridge returned malformed JSON.")
		return new /datum/tgs_http_result(null, FALSE)
	return new /datum/tgs_http_result(response.body, TRUE)

#undef TGS_HTTP_TIMEOUT
#undef HTTP_DEFAULT_TIMEOUT
