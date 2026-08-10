/// Свежий и дешёвый пинг-сэмпл означает, что скин отвечает и его можно спрашивать.
/datum/unit_test/skin_responsive_accepts_fresh_sample/Run()
	TEST_ASSERT(skin_responsive_from_sample(1000, 60, 1000), "Мгновенный сэмпл с пингом 60мс сочтён неотвечающим")
	TEST_ASSERT(skin_responsive_from_sample(1000, 60, 1000 + (30 SECONDS)), "Сэмпл возрастом 30с сочтён протухшим")

/// Клиент, ни разу не ответивший на пинг, спрашивать нельзя: на логине он занят подкачкой,
/// и именно там winget'ы стоили дороже всего.
/datum/unit_test/skin_responsive_rejects_silent_client/Run()
	TEST_ASSERT(!skin_responsive_from_sample(0, 0, 5000), "Клиент без единого пинг-сэмпла сочтён отвечающим")

/// Протухший сэмпл ничего не говорит о текущем состоянии клиента.
/datum/unit_test/skin_responsive_rejects_stale_sample/Run()
	TEST_ASSERT(!skin_responsive_from_sample(1000, 60, 1000 + (5 MINUTES)), "Сэмпл пятиминутной давности сочтён свежим")

/// Огромный round-trip - подпись подкачки ресурсов. В раунде 9870 такой клиент держал
/// winget до 125 секунд.
/datum/unit_test/skin_responsive_rejects_slow_client/Run()
	TEST_ASSERT(!skin_responsive_from_sample(1000, 66436, 1000), "Клиент с RTT 66 секунд сочтён отвечающим")
	TEST_ASSERT(!skin_responsive_from_sample(1000, 900, 1000), "Клиент с RTT 900мс должен считаться занятым")
	TEST_ASSERT(skin_responsive_from_sample(1000, 200, 1000), "Удалённый клиент с приемлемым RTT 200мс ошибочно заблокирован")

/// Не-клиента судить не о чем: вызывающий обязан вести себя как раньше.
/datum/unit_test/skin_responsive_passes_non_clients/Run()
	TEST_ASSERT(client_skin_responsive(null), "null сочтён неотвечающим клиентом")

/// Имена этапов должны различаться, иначе сводка нечитаема.
/datum/unit_test/client_resource_stage_names_are_distinct/Run()
	var/list/seen = list()
	for(var/stage in CLIENT_RESOURCE_STAGE_CONNECTED to CLIENT_RESOURCE_STAGE_UI_READY)
		var/name = client_resource_stage_name(stage)
		TEST_ASSERT_NOTNULL(name, "У этапа [stage] нет имени")
		TEST_ASSERT(!(name in seen), "Имя этапа «[name]» повторяется")
		seen += name

/// Browser devicePixelRatio is client-controlled and must never reach layout code
/// without numeric range validation.
/datum/unit_test/tgui_device_pixel_ratio_validation/Run()
	TEST_ASSERT_NULL(sanitize_tgui_device_pixel_ratio(null), "null devicePixelRatio was accepted")
	TEST_ASSERT_NULL(sanitize_tgui_device_pixel_ratio("1.25"), "text devicePixelRatio was coerced")
	TEST_ASSERT_NULL(sanitize_tgui_device_pixel_ratio(0), "zero devicePixelRatio was accepted")
	TEST_ASSERT_NULL(sanitize_tgui_device_pixel_ratio(0.49), "too-small devicePixelRatio was accepted")
	TEST_ASSERT_NULL(sanitize_tgui_device_pixel_ratio(4.01), "too-large devicePixelRatio was accepted")
	TEST_ASSERT_EQUAL(sanitize_tgui_device_pixel_ratio(0.5), 0.5, "minimum devicePixelRatio was rejected")
	TEST_ASSERT_EQUAL(sanitize_tgui_device_pixel_ratio(1.25), 1.25, "ordinary devicePixelRatio was changed")
	TEST_ASSERT_EQUAL(sanitize_tgui_device_pixel_ratio(4), 4, "maximum devicePixelRatio was rejected")
	TEST_ASSERT_EQUAL(sanitize_tgui_device_pixel_ratio(1.234), 1.23, "devicePixelRatio precision was not bounded")

/// Capability states are independent and callbacks from an older generation cannot
/// mutate the current lifecycle.
/datum/unit_test/client_resource_session_tracks_independent_capabilities/Run()
	var/datum/client_resource_session/session = new(null)
	var/generation = session.generation
	TEST_ASSERT(length(session.nonce), "resource session nonce was not generated")
	session.note_statbrowser_ready(reason = "unit test")
	session.invalidate_tgui("unit test", failed = TRUE)
	TEST_ASSERT_EQUAL(session.get_capability(CLIENT_CAPABILITY_STATBROWSER), CLIENT_CAPABILITY_READY, "tgui failure changed statbrowser state")
	TEST_ASSERT_EQUAL(session.get_capability(CLIENT_CAPABILITY_TGUI_PANEL), CLIENT_CAPABILITY_FAILED, "tgui failure state was not recorded")
	TEST_ASSERT_EQUAL(session.get_capability(CLIENT_CAPABILITY_BROWSER), CLIENT_CAPABILITY_DEGRADED, "overall browser health hid a failed tgui panel")
	TEST_ASSERT(!session.set_capability(CLIENT_CAPABILITY_STATBROWSER, CLIENT_CAPABILITY_FAILED, "stale callback", generation + 1), "stale generation update was accepted")
	TEST_ASSERT_EQUAL(session.get_capability(CLIENT_CAPABILITY_STATBROWSER), CLIENT_CAPABILITY_READY, "stale callback mutated capability state")
	var/datum/client_resource_session/reconnected_session = new(null)
	TEST_ASSERT(reconnected_session.generation > generation, "reconnect did not receive a newer session generation")
	TEST_ASSERT(reconnected_session.nonce != session.nonce, "reconnect reused a resource session nonce")
	session.invalidate_browser("unit test restart")
	TEST_ASSERT_EQUAL(session.get_capability(CLIENT_CAPABILITY_STATBROWSER), CLIENT_CAPABILITY_INVALIDATED, "browser reset left statbrowser ready")
	TEST_ASSERT_EQUAL(session.get_capability(CLIENT_CAPABILITY_TGUI_PANEL), CLIENT_CAPABILITY_INVALIDATED, "browser reset left tgui ready")
	qdel(reconnected_session)
	qdel(session)

/// Отчёт браузера недоверенный: неизвестное состояние обязано отбрасываться, а не
/// трактоваться «на всякий случай» как провал - иначе опечатка в JS выключала бы
/// подтверждение доступности у всех сразу.
/datum/unit_test/external_delivery_probe_state_mapping/Run()
	TEST_ASSERT_EQUAL(external_delivery_probe_state(CLIENT_DELIVERY_PROBE_OK), CLIENT_CAPABILITY_READY, "Успешная проба не подтвердила доступность")
	TEST_ASSERT_EQUAL(external_delivery_probe_state(CLIENT_DELIVERY_PROBE_HTTP_ERROR), CLIENT_CAPABILITY_DEGRADED, "Отказ хоста по файлу приравнен не к деградации")
	TEST_ASSERT_EQUAL(external_delivery_probe_state(CLIENT_DELIVERY_PROBE_BLOCKED), CLIENT_CAPABILITY_FAILED, "Недоступный адрес не признан провалом")
	TEST_ASSERT_EQUAL(external_delivery_probe_state(CLIENT_DELIVERY_PROBE_TIMEOUT), CLIENT_CAPABILITY_FAILED, "Таймаут не признан провалом")
	TEST_ASSERT_NULL(external_delivery_probe_state("whatever"), "Незнакомое состояние отчёта принято")
	TEST_ASSERT_NULL(external_delivery_probe_state(null), "Пустое состояние отчёта принято")
	TEST_ASSERT_NULL(external_delivery_probe_state(1), "Числовое состояние отчёта принято")

/// Цели известны заранее, и чужой ключ не должен доехать до capability.
/datum/unit_test/external_delivery_probe_targets_are_closed_set/Run()
	TEST_ASSERT(is_external_delivery_probe_target(CLIENT_DELIVERY_PROBE_TARGET_RSC), "Цель .rsc не опознана")
	TEST_ASSERT(is_external_delivery_probe_target(CLIENT_DELIVERY_PROBE_TARGET_ASSETS), "Цель браузерных ассетов не опознана")
	TEST_ASSERT(!is_external_delivery_probe_target("lobby"), "Цель, которой клиенту не выдавали, опознана")
	TEST_ASSERT(!is_external_delivery_probe_target(null), "Пустой ключ цели опознан")
	TEST_ASSERT_EQUAL(external_delivery_probe_capability(CLIENT_DELIVERY_PROBE_TARGET_RSC), CLIENT_CAPABILITY_RSC, "Цель .rsc привязана не к своей capability")
	TEST_ASSERT_EQUAL(external_delivery_probe_capability(CLIENT_DELIVERY_PROBE_TARGET_ASSETS), CLIENT_CAPABILITY_ASSET_CACHE, "Цель ассетов привязана не к своей capability")
	TEST_ASSERT_NULL(external_delivery_probe_capability("lobby"), "Незнакомой цели нашлась capability")

/// Числа приезжают из WebView, то есть настраиваются игроком. Обрезаем их до того,
/// как они попадут в лог и в отчёт админам.
/datum/unit_test/external_delivery_probe_numbers_are_bounded/Run()
	TEST_ASSERT_NULL(external_delivery_probe_duration_ms(null), "Отсутствующая длительность превратилась в число")
	TEST_ASSERT_NULL(external_delivery_probe_duration_ms("15000"), "Текстовая длительность принята")
	TEST_ASSERT_NULL(external_delivery_probe_duration_ms(-1), "Отрицательная длительность принята")
	TEST_ASSERT_EQUAL(external_delivery_probe_duration_ms(0), 0, "Мгновенный ответ отброшен")
	TEST_ASSERT_EQUAL(external_delivery_probe_duration_ms(42.7), 43, "Длительность не округлена до миллисекунд")
	TEST_ASSERT_EQUAL(external_delivery_probe_duration_ms(1e9), CLIENT_DELIVERY_PROBE_MAX_REPORTED_MS, "Длительность не обрезана по разумному пределу")
	TEST_ASSERT_EQUAL(external_delivery_probe_http_status(206), 206, "Обычный HTTP-статус изменён")
	TEST_ASSERT_EQUAL(external_delivery_probe_http_status(0), 0, "Непрозрачный ответ потерял свой нулевой статус")
	TEST_ASSERT_EQUAL(external_delivery_probe_http_status(9000), 0, "Несуществующий HTTP-статус принят")
	TEST_ASSERT_EQUAL(external_delivery_probe_http_status("200"), 0, "Текстовый HTTP-статус принят")

/// Текст ошибки едет из браузера прямо в asset.log и в чат админам.
/datum/unit_test/external_delivery_probe_detail_is_sanitized/Run()
	TEST_ASSERT_EQUAL(external_delivery_probe_detail(null), "", "Пустой detail стал не пустой строкой")
	TEST_ASSERT_EQUAL(external_delivery_probe_detail(200), "", "Числовой detail принят")
	var/scripted = external_delivery_probe_detail("<script>alert(1)</script>")
	TEST_ASSERT(!findtext(scripted, "<script"), "Разметка из detail доехала до лога: [scripted]")
	var/long_detail = external_delivery_probe_detail("a" + "aaaaaaaaaa" + "aaaaaaaaaa" + "aaaaaaaaaa" + "aaaaaaaaaa" + "aaaaaaaaaa" + "aaaaaaaaaa" + "aaaaaaaaaa" + "aaaaaaaaaa" + "aaaaaaaaaa" + "aaaaaaaaaa")
	TEST_ASSERT(length(long_detail) <= CLIENT_DELIVERY_PROBE_DETAIL_MAX_LENGTH, "Длинный detail не обрезан: [length(long_detail)] символов")

/// Клиент в счётчиках раунда учитывается по САМОЙ ПЛОХОЙ цели: доступный статбраузер
/// не отменяет неприехавшего архива.
/datum/unit_test/external_delivery_probe_worst_state_wins/Run()
	TEST_ASSERT_EQUAL(external_delivery_probe_worst_state(null, CLIENT_CAPABILITY_READY), CLIENT_CAPABILITY_READY, "Первая цель не задала состояние клиента")
	TEST_ASSERT_EQUAL(external_delivery_probe_worst_state(CLIENT_CAPABILITY_READY, CLIENT_CAPABILITY_DEGRADED), CLIENT_CAPABILITY_DEGRADED, "Успешная цель скрыла деградацию")
	TEST_ASSERT_EQUAL(external_delivery_probe_worst_state(CLIENT_CAPABILITY_DEGRADED, CLIENT_CAPABILITY_FAILED), CLIENT_CAPABILITY_FAILED, "Деградация скрыла полный провал")
	TEST_ASSERT_EQUAL(external_delivery_probe_worst_state(CLIENT_CAPABILITY_FAILED, CLIENT_CAPABILITY_READY), CLIENT_CAPABILITY_FAILED, "Успешная цель скрыла полный провал")

/// Причина уезжает в capability_reasons и в лог, поэтому она обязана называть и
/// диагноз, и цену: «недоступно» без миллисекунд не отличить от «отвечает медленно».
/datum/unit_test/external_delivery_probe_reason_is_readable/Run()
	var/ok_reason = external_delivery_probe_reason(CLIENT_DELIVERY_PROBE_OK, 200, 42, "")
	TEST_ASSERT(findtext(ok_reason, "200"), "Причина успеха не назвала HTTP-статус: [ok_reason]")
	TEST_ASSERT(findtext(ok_reason, "42мс"), "Причина успеха не назвала длительность: [ok_reason]")
	var/opaque_reason = external_delivery_probe_reason(CLIENT_DELIVERY_PROBE_OK, 0, 15, "no-cors")
	TEST_ASSERT(!findtext(opaque_reason, "(0)"), "Непрозрачный ответ показал нулевой статус как настоящий: [opaque_reason]")
	var/blocked_reason = external_delivery_probe_reason(CLIENT_DELIVERY_PROBE_BLOCKED, 0, 3, "Failed to fetch")
	TEST_ASSERT(findtext(blocked_reason, "Failed to fetch"), "Причина провала не назвала текст ошибки: [blocked_reason]")
	var/silent_reason = external_delivery_probe_reason(CLIENT_DELIVERY_PROBE_TIMEOUT, 0, null, "")
	TEST_ASSERT(findtext(silent_reason, "нет ответа"), "Причина таймаута нечитаема: [silent_reason]")
	TEST_ASSERT(!findtext(silent_reason, "мс"), "Причина без замера всё равно назвала длительность: [silent_reason]")

/// Отчёт админам обязан называть все четыре числа: без «без ответа» подтвердившие
/// доступность читаются как «все, кого спросили».
/datum/unit_test/external_delivery_probe_report_counts_silent_clients/Run()
	var/saved_requested = GLOB.external_delivery_probes_requested
	var/saved_ok = GLOB.external_delivery_probes_ok
	var/saved_degraded = GLOB.external_delivery_probes_degraded
	var/saved_failed = GLOB.external_delivery_probes_failed
	var/list/saved_failures = GLOB.external_delivery_probe_failures

	GLOB.external_delivery_probes_requested = 0
	var/list/idle_lines = build_client_delivery_probe_report_lines()

	GLOB.external_delivery_probes_requested = 10
	GLOB.external_delivery_probes_ok = 6
	GLOB.external_delivery_probes_degraded = 1
	GLOB.external_delivery_probes_failed = 2
	GLOB.external_delivery_probe_failures = list("тестклиент" = "rsc failed (проба клиента: адрес не открылся)")
	var/list/lines = build_client_delivery_probe_report_lines()

	GLOB.external_delivery_probes_requested = saved_requested
	GLOB.external_delivery_probes_ok = saved_ok
	GLOB.external_delivery_probes_degraded = saved_degraded
	GLOB.external_delivery_probes_failed = saved_failed
	GLOB.external_delivery_probe_failures = saved_failures

	TEST_ASSERT_EQUAL(length(idle_lines), 1, "Отчёт без единой пробы построил больше одной строки")
	var/summary = lines[1]
	TEST_ASSERT(findtext(summary, "подтвердили доступность 6"), "Отчёт неверно назвал подтвердивших: [summary]")
	TEST_ASSERT(findtext(summary, "без ответа 1"), "Отчёт неверно посчитал молчунов: [summary]")
	TEST_ASSERT(length(lines) > 1, "Отчёт с провалами не назвал ни одного клиента поимённо")
	TEST_ASSERT(findtext(lines[2], "тестклиент"), "Отчёт не назвал провалившегося клиента: [lines[2]]")

/// Сводка обязана считать умершими на выдаче ресурсов ровно те соединения, что не дошли
/// до статбраузера.
/datum/unit_test/connection_stage_summary_counts_delivery_deaths/Run()
	var/list/saved = GLOB.round_connection_stage_deaths
	GLOB.round_connection_stage_deaths = list(
		"[CLIENT_RESOURCE_STAGE_CONNECTED]" = 3,
		"[CLIENT_RESOURCE_STAGE_REQUESTED]" = 1,
		"[CLIENT_RESOURCE_STAGE_UI_READY]" = 6,
	)
	var/line = build_connection_stage_summary()
	GLOB.round_connection_stage_deaths = saved
	TEST_ASSERT_NOTNULL(line, "Сводка по этапам не построилась при непустых данных")
	TEST_ASSERT(findtext(line, "закрытых соединений 10"), "Сводка неверно сложила закрытые соединения: [line]")
	TEST_ASSERT(findtext(line, "не дожили до статбраузера 4"), "Сводка неверно посчитала смерти на выдаче ресурсов: [line]")
	TEST_ASSERT(findtext(line, "(40%)"), "Сводка неверно посчитала долю: [line]")

/// Без закрытых соединений строки быть не должно - пустая сводка только зашумляет лог.
/datum/unit_test/connection_stage_summary_silent_when_empty/Run()
	var/list/saved = GLOB.round_connection_stage_deaths
	GLOB.round_connection_stage_deaths = list()
	var/line = build_connection_stage_summary()
	GLOB.round_connection_stage_deaths = saved
	TEST_ASSERT_NULL(line, "Пустая сводка по этапам всё равно построила строку: [line]")

/// Пропущенные обращения к скину считаются отдельно от состоявшихся: они не стоили
/// времени, но без них упавшее число winget выглядит необъяснимым.
/// Работаем на живой подсистеме, как это делает tick_spike_recorder, и убираем за собой.
/datum/unit_test/skipped_blocking_calls_are_counted_apart/Run()
	var/datum/controller/subsystem/tick_spikes/recorder = SStick_spikes
	TEST_ASSERT_NOTNULL(recorder, "SStick_spikes не поднялся")
	recorder.reset_state()

	recorder.record_blocking_call("winget", "тестклиент: mapwindow.size", 40)
	TEST_ASSERT_NULL(recorder.build_skipped_blocking_line(), "Строка про пропуски появилась без пропусков")

	recorder.record_skipped_blocking_call("winget")
	recorder.record_skipped_blocking_call("winget")

	TEST_ASSERT_EQUAL(recorder.blocking_calls, 1, "Пропуск попал в счётчик состоявшихся вызовов")
	TEST_ASSERT_EQUAL(recorder.blocking_skipped_calls, 2, "Пропуски не посчитаны")
	TEST_ASSERT_EQUAL(recorder.blocking_total_ms, 40, "Пропуск добавил времени в итог")

	var/line = recorder.build_skipped_blocking_line()
	TEST_ASSERT_NOTNULL(line, "Строка про пропуски не построилась")
	TEST_ASSERT(findtext(line, "winget x2"), "В строке про пропуски нет разбивки по типу: [line]")

	// Сводка обязана называть пропуски отдельной строкой, а не мешать их со стоимостью.
	var/summary = recorder.build_blocking_summary()
	TEST_ASSERT(findtext(summary, "пропущены"), "Сводка умолчала о пропущенных обращениях: [summary]")

	recorder.reset_state()
	TEST_ASSERT_EQUAL(recorder.blocking_skipped_calls, 0, "reset_state() не обнулил счётчик пропусков")

/// Размер в сводке и в сообщении игроку должен читаться, а не быть числом байт.
/datum/unit_test/personal_music_box_size_text_is_readable/Run()
	TEST_ASSERT_EQUAL(personal_music_box_size_text(3343100), "3.2 МБ", "Мегабайты отформатированы неверно")
	TEST_ASSERT_EQUAL(personal_music_box_size_text(382510), "374 КБ", "Килобайты отформатированы неверно")

/// Сводка по музыке игроков обязана называть и объём, и выигрыш дедупа: ради этих двух
/// чисел она и заводилась. Данные раунда 9870 - 19 файлов, из которых один был дублем.
/datum/unit_test/personal_music_box_summary_reports_dedup/Run()
	var/list/saved_hashes = GLOB.personal_music_box_tracks_by_hash
	var/list/saved_bytes = GLOB.personal_music_box_bytes_by_ckey
	var/saved_total = GLOB.personal_music_box_bytes_total
	var/saved_deduped = GLOB.personal_music_box_bytes_deduped

	GLOB.personal_music_box_tracks_by_hash = list("хеш-один" = "путь-один", "хеш-два" = "путь-два")
	GLOB.personal_music_box_bytes_by_ckey = list("snaipernoob" = 8355840)
	GLOB.personal_music_box_bytes_total = 8355840
	GLOB.personal_music_box_bytes_deduped = 3343100
	var/line = build_personal_music_box_summary()

	GLOB.personal_music_box_tracks_by_hash = saved_hashes
	GLOB.personal_music_box_bytes_by_ckey = saved_bytes
	GLOB.personal_music_box_bytes_total = saved_total
	GLOB.personal_music_box_bytes_deduped = saved_deduped

	TEST_ASSERT_NOTNULL(line, "Сводка по музыке игроков не построилась при непустых данных")
	TEST_ASSERT(findtext(line, "новых треков 2"), "Сводка не назвала число уникальных треков: [line]")
	TEST_ASSERT(findtext(line, "дедуп сэкономил 3.2 МБ"), "Сводка не назвала выигрыш дедупа: [line]")
	TEST_ASSERT(findtext(line, "snaipernoob"), "Сводка не назвала игрока: [line]")

/// Без единой загрузки строки быть не должно.
/datum/unit_test/personal_music_box_summary_silent_when_empty/Run()
	var/saved_total = GLOB.personal_music_box_bytes_total
	var/saved_deduped = GLOB.personal_music_box_bytes_deduped
	GLOB.personal_music_box_bytes_total = 0
	GLOB.personal_music_box_bytes_deduped = 0
	var/line = build_personal_music_box_summary()
	GLOB.personal_music_box_bytes_total = saved_total
	GLOB.personal_music_box_bytes_deduped = saved_deduped
	TEST_ASSERT_NULL(line, "Пустая сводка по музыке всё равно построила строку: [line]")
