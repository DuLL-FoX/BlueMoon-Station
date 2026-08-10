/datum/plug13_connection
	/// All Plug13 requests are external and optional; never retain native jobs indefinitely.
	var/static/http_timeout = 10 SECONDS
	var/is_connected = FALSE
	var/pending = FALSE
	var/error
	var/username
	var/code
	var/emote_sends_failed = 0
	var/failed_code_tries = 0
	var/client/owner

/datum/plug13_connection/New(client/owner)
	if (!owner)
		CRASH("Plug13 connection was created without an owner!")
	src.owner = owner
	RegisterSignal(owner, COMSIG_PARENT_QDELETING, PROC_REF(on_owner_qdeleting))

/datum/plug13_connection/Destroy()
	if(owner)
		UnregisterSignal(owner, COMSIG_PARENT_QDELETING)
	owner = null
	return ..()

/// Break the owner cycle before /client's hard deletion and make sleeping requests harmless.
/datum/plug13_connection/proc/on_owner_qdeleting()
	SIGNAL_HANDLER
	owner = null

/datum/plug13_connection/proc/connect()
	if (is_connected || !code || pending) return
	if (!owner) return

	if (failed_code_tries > 30)
		error = "Слишком ошибок ввода кода"
		return

	pending = TRUE
	error = ""

	var/body = list(
		"code" = code,
		"secret" = CONFIG_GET(string/plug13_secret),
		"key" = owner.key
	)

	var/datum/http_response/response = world_safe_http_request(RUSTG_HTTP_METHOD_POST, "[CONFIG_GET(string/plug13_url)]/api/game/connect", json_encode(body), timeout = http_timeout)
	pending = FALSE
	if(!owner)
		return

	if(isnull(response) || response.errored || response.status_code != 200)
		error = "Ошибка соединения с Plug13"
		return

	var/list/data = safe_json_decode_list(response.body)
	if(isnull(data))
		error = "Plug13 вернул некорректный ответ"
		return

	if (data["error"])
		error = data["error"]
		failed_code_tries++
		return
	if(!istext(data["username"]) || !length(data["username"]))
		error = "Plug13 вернул ответ без имени пользователя"
		return

	is_connected = TRUE
	username = data["username"]


/datum/plug13_connection/proc/disconnect()
	is_connected = FALSE
	emote_sends_failed = 0
	username = null

/datum/plug13_connection/proc/send_emote(emote, strength, duration)
	set waitfor = FALSE

	if (!is_connected || !code) return
	if (!owner) return

	if (!(emote in PLUG13_ALL_EMOTES))
		CRASH("Plug13 error - Invalid emote type: \"[emote]\"")

	if (!isnum(strength) || strength <= 0 || strength > 100)
		CRASH("Plug13 error - Invalid emote strength: [strength]")

	if (!isnum(duration) || duration <= 0 || duration > PLUG13_MAX_CLIENT_INTERACTION_DURATION)
		CRASH("Plug13 error - Invalid emote duration: [duration]")

	var/body = list(
		"code" = code,
		"secret" = CONFIG_GET(string/plug13_secret),
		"emote" = emote,
		"strength" = strength,
		"duration" = duration,
		"key" = owner.key
	)

	var/datum/http_response/response = world_safe_http_request(RUSTG_HTTP_METHOD_POST, "[CONFIG_GET(string/plug13_url)]/api/game/emote", json_encode(body), timeout = http_timeout)
	if(!owner)
		return

	if(isnull(response) || response.errored || FLOOR(response.status_code/100, 1) != 2) // 2xx codes
		if (++emote_sends_failed > 10)
			error = "Слишком много неудачных запросов"
			disconnect()
		return

	emote_sends_failed = 0
