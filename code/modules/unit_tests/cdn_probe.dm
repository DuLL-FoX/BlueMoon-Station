/// A failed RSC mirror must fail the whole client rotation even when the primary works.
/datum/unit_test/cdn_probe_failed_mirror_wins/Run()
	var/list/verdicts = list(
		"https://primary.example.test/archive.zip" = list("healthy", "ответ 200"),
		"https://broken.example.test/archive.zip" = list("failed", "ответ 404"),
	)
	var/list/summary = summarize_cdn_probe_verdicts(verdicts)
	TEST_ASSERT_EQUAL(summary[1], "failed", "Исправный primary скрыл отказ RSC-зеркала")
	TEST_ASSERT(findtext(summary[2], "broken.example.test"), "Сводка не назвала отказавшее зеркало: [summary[2]]")

/// A HEAD refusal is not proof that every mirror has the archive.
/datum/unit_test/cdn_probe_indeterminate_mirror_prevents_success/Run()
	var/list/verdicts = list(
		"https://primary.example.test/archive.zip" = list("healthy", "ответ 200"),
		"https://headless.example.test/archive.zip" = list("indeterminate", "ответ 405: HEAD не принимается"),
	)
	var/list/summary = summarize_cdn_probe_verdicts(verdicts)
	TEST_ASSERT_EQUAL(summary[1], "indeterminate", "Непроверенное зеркало сочтено здоровым")
	TEST_ASSERT(findtext(summary[2], "headless.example.test"), "Сводка не назвала непроверенное зеркало: [summary[2]]")

/// All mirrors answering is the only healthy aggregate result.
/datum/unit_test/cdn_probe_all_mirrors_healthy/Run()
	var/list/verdicts = list(
		"https://primary.example.test/archive.zip" = list("healthy", "ответ 200"),
		"https://mirror.example.test/archive.zip" = list("healthy", "ответ 302"),
	)
	var/list/summary = summarize_cdn_probe_verdicts(verdicts)
	TEST_ASSERT_EQUAL(summary[1], "healthy", "Исправная ротация зеркал не признана здоровой")

/// The DM timeout must reach rustg itself; an outer polling deadline alone leaves a native job behind.
/datum/unit_test/http_request_forwards_native_timeout/Run()
	var/datum/http_request/request = new()
	request.prepare(RUSTG_HTTP_METHOD_HEAD, "https://example.test/archive.zip", timeout_seconds = 20)
	var/list/options = json_decode(request.build_options())
	TEST_ASSERT_EQUAL(options["timeout_seconds"], 20, "Таймаут запроса не передан в rustg")

/// A regular rust-g response must survive schema validation intact.
/datum/unit_test/http_response_decodes_valid_json/Run()
	var/datum/http_request/request = new()
	request.started = TRUE
	request.completed = TRUE
	request._raw_response = json_encode(list(
		"status_code" = 200,
		"headers" = list("content-type" = "text/plain"),
		"body" = "ok",
	))

	var/datum/http_response/response = request.into_response()
	TEST_ASSERT(!response.errored, "Valid rust-g response was rejected: [response.error]")
	TEST_ASSERT_EQUAL(response.status_code, 200, "HTTP status was not decoded")
	TEST_ASSERT_EQUAL(response.headers["content-type"], "text/plain", "HTTP headers were not decoded")
	TEST_ASSERT_EQUAL(response.body, "ok", "HTTP body was not decoded")

/// rust-g 6.2/ureq returns 4xx and 5xx as text errors, but the status is still usable.
/datum/unit_test/http_response_recovers_ureq_status_error/Run()
	var/datum/http_request/request = new()
	request.started = TRUE
	request.completed = TRUE
	request._raw_response = "https://example.test/archive.zip: status code 405"

	var/datum/http_response/response = request.into_response()
	TEST_ASSERT(!response.errored, "ureq HTTP status was treated as a transport error: [response.error]")
	TEST_ASSERT_EQUAL(response.status_code, 405, "ureq HTTP status was not recovered")
	TEST_ASSERT(response.status_only, "Loss of body and headers on ureq status errors was not marked")

/// Redirect context is part of ureq's Display form and must not hide the final status.
/datum/unit_test/http_response_recovers_redirected_ureq_status_error/Run()
	var/datum/http_request/request = new()
	request.started = TRUE
	request.completed = TRUE
	request._raw_response = "https://cdn.example.test/archive.zip: status code 501 (redirected from https://example.test/archive.zip)"

	var/datum/http_response/response = request.into_response()
	TEST_ASSERT(!response.errored, "Redirected ureq HTTP status was treated as a transport error")
	TEST_ASSERT_EQUAL(response.status_code, 501, "Redirected ureq HTTP status was not recovered")

/// Only the anchored ureq error form is trusted; arbitrary transport text stays an error.
/datum/unit_test/http_response_rejects_spoofed_or_malformed_data/Run()
	var/datum/http_request/request = new()
	request.started = TRUE
	request.completed = TRUE
	request._raw_response = "request URL contained status code 404 but connection failed afterwards"
	var/datum/http_response/response = request.into_response()
	TEST_ASSERT(response.errored, "Unanchored status text was accepted as an HTTP response")

	var/datum/http_request/malformed_request = new()
	malformed_request.started = TRUE
	malformed_request.completed = TRUE
	malformed_request._raw_response = "{}"
	var/datum/http_response/malformed_response = malformed_request.into_response()
	TEST_ASSERT(malformed_response.errored, "Malformed rust-g response object was accepted")

/// Remote JSON consumers receive a list or null, never a json_decode runtime.
/datum/unit_test/safe_json_decode_list_rejects_invalid_shapes/Run()
	var/list/decoded = safe_json_decode_list("{\"status\":\"ok\"}")
	TEST_ASSERT_NOTNULL(decoded, "Valid JSON object was rejected")
	TEST_ASSERT_EQUAL(decoded["status"], "ok", "Valid JSON object was decoded incorrectly")
	TEST_ASSERT_NULL(safe_json_decode_list("not json"), "Malformed JSON was accepted")
	TEST_ASSERT_NULL(safe_json_decode_list("42"), "JSON scalar was accepted where a list was required")
