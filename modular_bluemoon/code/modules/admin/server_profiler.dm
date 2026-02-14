/// Global proc: categorize a proc name into a system category based on path patterns.
/// Results cached globally in GLOB.profiler_category_cache (proc paths never change during a round).
/// Order matters: more specific patterns checked before broader ones.
/proc/categorize_profile_proc(name)
	var/cached = GLOB.profiler_category_cache[name]
	if(cached)
		return cached
	var/cat
	// 1. Profiler's own overhead
	if(findtext(name, "/server_profiler") || findtext(name, "/log_profiler"))
		cat = "profiler_self"
	// 2. TGUI / UI system
	else if(findtext(name, "/tgui") || findtext(name, "/ui_data") || findtext(name, "/ui_act") || findtext(name, "/ui_interact") || findtext(name, "/ui_static_data") || findtext(name, "/ui_close"))
		cat = "tgui"
	// 3. Atmosphere (specific SS before generic SS check)
	else if(findtext(name, "/datum/controller/subsystem/air") || findtext(name, "/atmos") || findtext(name, "update_air") || findtext(name, "/gas_mixture") || findtext(name, "process_turfs") || findtext(name, "/datum/pipeline"))
		cat = "atmos"
	// 4. AI controllers (before generic datum checks)
	else if(findtext(name, "/datum/ai") || findtext(name, "/ai_controller") || findtext(name, "/datum/ai_behavior"))
		cat = "ai"
	// 5. Components / Elements / DCS signals (before generic datum checks)
	else if(findtext(name, "/datum/component") || findtext(name, "/datum/element") || findtext(name, "RegisterSignal") || findtext(name, "UnregisterSignal") || findtext(name, "_SendSignal"))
		cat = "components"
	// 6. Assets (before generic datum checks)
	else if(findtext(name, "/datum/asset") || findtext(name, "icon2base64") || findtext(name, "md5filepath") || findtext(name, "spritesheet"))
		cat = "assets"
	// 7. Subsystems (generic, atmos already handled above)
	else if(findtext(name, "/datum/controller/subsystem"))
		cat = "subsystems"
	// 8. Rendering / overlays / icon updates
	else if(findtext(name, "add_overlay") || findtext(name, "cut_overlay") || findtext(name, "build_appearance_list") || findtext(name, "update_overlays") || findtext(name, "update_icon") || findtext(name, "update_appearance") || findtext(name, "/mutable_appearance") || findtext(name, "icon_smooth"))
		cat = "rendering"
	// 9. Lighting
	else if(findtext(name, "/lighting") || findtext(name, "/light_source") || findtext(name, "update_light"))
		cat = "lighting"
	// 10. Map / turfs / map parsing
	else if(findtext(name, "/turf") || findtext(name, "/datum/parsed_map") || findtext(name, "/datum/map_template") || findtext(name, "/datum/cameranet"))
		cat = "map"
	// 11. Machines (before broader /obj checks)
	else if(findtext(name, "/obj/machinery"))
		cat = "machines"
	// 12. Items
	else if(findtext(name, "/obj/item"))
		cat = "items"
	// 13. Mobs (expanded to all /mob/ procs)
	else if(findtext(name, "/mob/") || findtext(name, "/Life"))
		cat = "mobs"
	// 14. Timers / callbacks
	else if(findtext(name, "timer") || findtext(name, "callback") || findtext(name, "/datum/timedevent"))
		cat = "timers"
	// 15. Fallback
	else
		cat = "other"
	GLOB.profiler_category_cache[name] = cat
	return cat

/// Get Russian display name for a profiler category ID
/proc/get_profiler_category_name(cat_id)
	switch(cat_id)
		if("atmos")
			return "Атмосфера"
		if("machines")
			return "Машины"
		if("mobs")
			return "Мобы"
		if("lighting")
			return "Освещение"
		if("rendering")
			return "Рендеринг"
		if("tgui")
			return "TGUI"
		if("subsystems")
			return "Подсистемы"
		if("timers")
			return "Таймеры"
		if("map")
			return "Карта/Турфы"
		if("components")
			return "Компоненты"
		if("ai")
			return "ИИ"
		if("items")
			return "Предметы"
		if("assets")
			return "Ассеты"
		if("profiler_self")
			return "Профайлер"
		if("other")
			return "Другое"
	return cat_id

// =====================================================
// Tab constants (must match TGUI)
// =====================================================
#define PROFILER_TAB_OVERVIEW 1
#define PROFILER_TAB_ANALYSIS 2
#define PROFILER_TAB_SUBSYSTEMS 3
#define PROFILER_TAB_PROFILING 4

/// Server Performance Profiler — TGUI admin panel for real-time lag diagnostics
/datum/server_profiler
	/// Client who opened this profiler
	var/client/owner
	/// Cached parsed profile data (top PROFILER_BUFFER_MAX entries by self time)
	var/list/cached_profile_data
	/// Cached category aggregation data
	var/list/cached_category_data
	/// Previous snapshot self times for delta tracking (proc_name -> self_time)
	var/list/previous_self_times
	/// Cached total self time across all procs
	var/cached_total_self = 0
	/// world.time of last profile data fetch
	var/last_profile_refresh = 0
	/// How often to auto-refresh profile data (deciseconds)
	var/profile_refresh_interval = 50
	/// Whether we started profiling for this viewer session
	var/profiling_active = FALSE
	/// How many top procs to show (sent to TGUI for client-side truncation)
	var/top_n = 100
	/// Last status message for UI display
	var/debug_status = ""
	/// Cached per-category top procs for Analysis tab drill-down (category_id -> list of top 10 proc entries)
	var/list/cached_category_procs
	/// Currently active tab (synced from TGUI)
	var/active_tab = PROFILER_TAB_OVERVIEW

/datum/server_profiler/New(client/C)
	. = ..()
	owner = C
	// If profiling is already running (from world.dm init or SSprofiler), don't restart — PROFILE_START resets accumulated data.
	if(!SSprofiler.profiling_active)
		world.Profile(PROFILE_START)
		SSprofiler.profiling_active = TRUE
		debug_status = "Профилирование запущено. Ожидание [profile_refresh_interval / 10] сек."
		last_profile_refresh = world.time
	else
		debug_status = "Профилирование уже активно. Загрузка данных..."
		last_profile_refresh = 0
	profiling_active = TRUE

/datum/server_profiler/Destroy(force, ...)
	if(profiling_active && !CONFIG_GET(flag/auto_profile))
		world.Profile(PROFILE_STOP)
		SSprofiler.profiling_active = FALSE
	owner = null
	cached_profile_data = null
	cached_category_procs = null
	SStgui.close_uis(src)
	return ..()

/datum/server_profiler/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "ServerProfiler")
		ui.open()
		ui.set_autoupdate(TRUE)

/datum/server_profiler/ui_state(mob/user)
	return GLOB.admin_state

/datum/server_profiler/ui_data(mob/user)
	var/list/data = list()

	// Always-sent lightweight data
	data["active_tab"] = active_tab
	data["profiling_active"] = profiling_active
	data["profile_refresh_interval"] = profile_refresh_interval
	data["top_n"] = top_n
	data["ssprofiler_active"] = CONFIG_GET(flag/auto_profile)

	// Overview metrics — cheap, always sent
	data["cpu"] = world.cpu
	data["fps"] = world.fps
	data["tick_lag"] = world.tick_lag
	data["instances"] = world.contents.len
	data["players"] = GLOB.clients.len
	data["tick_drift"] = Master ? round(Master.tickdrift, 0.1) : 0
	data["tick_drift_pct"] = Master ? round((Master.tickdrift / max(1, (world.time / world.tick_lag))) * 100, 0.1) : 0
	data["mc_iteration"] = Master ? Master.iteration : 0
	data["map_tick"] = round(MAPTICK_LAST_INTERNAL_TICK_USAGE, 0.1)
	data["time_dilation"] = round(SStime_track.time_dilation_current, 0.1)
	data["time_dilation_avg_fast"] = round(SStime_track.time_dilation_avg_fast, 0.1)
	data["time_dilation_avg"] = round(SStime_track.time_dilation_avg, 0.1)
	data["time_dilation_avg_slow"] = round(SStime_track.time_dilation_avg_slow, 0.1)

	// Tab-specific data — only build what the active tab needs
	switch(active_tab)
		if(PROFILER_TAB_OVERVIEW)
			// Queues for overview
			data["queues"] = build_queue_data()

		if(PROFILER_TAB_ANALYSIS)
			// Queues + profile data + categories
			data["queues"] = build_queue_data()
			if(profiling_active && (world.time >= last_profile_refresh + profile_refresh_interval))
				fetch_profile_data()
			data["debug_status"] = debug_status
			data["profile_data"] = cached_profile_data || list()
			data["categories"] = cached_category_data || list()
			data["category_procs"] = cached_category_procs || list()
			data["total_self_time"] = round(cached_total_self, 0.01)

		if(PROFILER_TAB_SUBSYSTEMS)
			// Subsystems data
			data["subsystems"] = build_subsystem_data()

		if(PROFILER_TAB_PROFILING)
			// Profile data only
			if(profiling_active && (world.time >= last_profile_refresh + profile_refresh_interval))
				fetch_profile_data()
			data["debug_status"] = debug_status
			data["profile_data"] = cached_profile_data || list()
			data["total_self_time"] = round(cached_total_self, 0.01)

	return data

/// Build subsystem data list for the Subsystems tab
/datum/server_profiler/proc/build_subsystem_data()
	var/list/subsystems = list()
	if(!Master)
		return subsystems
	for(var/datum/controller/subsystem/SS as anything in Master.subsystems)
		if(SS.flags & SS_NO_FIRE)
			continue
		var/list/ss_entry = list(
			"name" = SS.name,
			"cost" = round(SS.cost, 0.01),
			"tick_usage" = round(SS.tick_usage, 0.01),
			"tick_overrun" = round(SS.tick_overrun, 0.01),
			"ticks" = round(SS.ticks, 0.1),
			"times_fired" = SS.times_fired,
			"state" = SS.state_letter(),
			"wait" = SS.wait,
			"priority" = SS.priority,
			"can_fire" = SS.can_fire,
		)
		// SSair subcost drill-down
		if(istype(SS, /datum/controller/subsystem/air))
			var/datum/controller/subsystem/air/SSA = SS
			ss_entry["subcosts"] = list(
				list("name" = "Турфы", "cost" = round(SSA.cost_turfs, 0.01)),
				list("name" = "Выравнивание", "cost" = round(SSA.cost_equalize, 0.01)),
				list("name" = "Группы", "cost" = round(SSA.cost_groups, 0.01)),
				list("name" = "Высок. давление", "cost" = round(SSA.cost_highpressure, 0.01)),
				list("name" = "Горячие точки", "cost" = round(SSA.cost_hotspots, 0.01)),
				list("name" = "Теплопроводность", "cost" = round(SSA.cost_superconductivity, 0.01)),
				list("name" = "Трубопроводы", "cost" = round(SSA.cost_pipenets, 0.01)),
				list("name" = "Перестройка", "cost" = round(SSA.cost_rebuilds, 0.01)),
				list("name" = "Постобработка", "cost" = round(SSA.cost_post_process, 0.01)),
				list("name" = "Атмос-машины", "cost" = round(SSA.cost_atmos_machinery, 0.01)),
			)
		subsystems += list(ss_entry)
	return subsystems

/// Build processing queue data
/datum/server_profiler/proc/build_queue_data()
	return list(
		list("name" = "SSmachines", "count" = length(SSmachines.processing)),
		list("name" = "SSmobs (living)", "count" = length(GLOB.mob_living_list)),
		list("name" = "SSprocessing", "count" = length(SSprocessing.processing)),
		list("name" = "SSfastprocess", "count" = length(SSfastprocess.processing)),
		list("name" = "SSobj", "count" = length(SSobj.processing)),
		list("name" = "SStimer", "count" = length(SStimer.timer_id_dict)),
	)

/datum/server_profiler/ui_act(action, params, datum/tgui/ui)
	. = ..()
	if(.)
		return

	if(!check_rights_for(usr?.client, R_ADMIN))
		return

	switch(action)
		if("set_tab")
			var/new_tab = text2num(params["tab"])
			if(new_tab && new_tab >= 1 && new_tab <= 4)
				active_tab = new_tab
			return TRUE
		if("start_profile")
			world.Profile(PROFILE_START)
			profiling_active = TRUE
			SSprofiler.profiling_active = TRUE
			last_profile_refresh = 0
			cached_profile_data = null
			debug_status = "Профилирование запущено. Ожидание данных..."
			log_admin("[key_name(usr)] started server profiling via Server Profiler panel.")
			message_admins("[key_name_admin(usr)] started server profiling.")
			return TRUE
		if("stop_profile")
			fetch_profile_data()
			world.Profile(PROFILE_STOP)
			profiling_active = FALSE
			SSprofiler.profiling_active = FALSE
			debug_status = "Профилирование остановлено. Последний снимок сохранён."
			log_admin("[key_name(usr)] stopped server profiling via Server Profiler panel.")
			message_admins("[key_name_admin(usr)] stopped server profiling.")
			return TRUE
		if("refresh_profile")
			fetch_profile_data()
			return TRUE
		if("set_top_n")
			var/new_n = text2num(params["top_n"])
			if(new_n && new_n > 0 && new_n <= 500)
				top_n = new_n
			return TRUE
		if("set_refresh_interval")
			var/new_interval = text2num(params["interval"])
			if(new_interval && new_interval >= 10 && new_interval <= 600)
				profile_refresh_interval = new_interval
			return TRUE
		if("dump_csv")
			dump_enhanced_csv()
			to_chat(usr, span_notice("CSV-снимок производительности сохранён в лог-директорию."))
			return TRUE
		if("dump_hotspots")
			dump_proc_hotspots()
			to_chat(usr, span_notice("Дамп горячих точек профилирования сохранён в лог-директорию."))
			return TRUE

/datum/server_profiler/proc/fetch_profile_data()
	last_profile_refresh = world.time

	// Use global cached profile data instead of independent world.Profile() call
	var/list/parsed = SSprofiler.get_cached_profile()
	if(!length(parsed))
		debug_status = "Нет данных профилирования. Профилирование не активно?"
		cached_profile_data = list()
		cached_category_data = list()
		cached_category_procs = list()
		cached_total_self = 0
		return

	// Single pass: compute totals, category aggregates, and maintain bounded top-N buffer
	var/total_self = 0
	var/list/new_self_times = list()
	var/list/cat_totals = list()
	var/list/cat_calls = list()
	var/list/cat_count = list()
	var/list/cat_top_procs = list()
	var/list/result = list()
	var/total_procs = 0
	var/min_self_in_buffer = 0

	for(var/list/entry_list in parsed)
		var/self_time = entry_list["self"]
		var/total_time = entry_list["total"]
		var/real_time = entry_list["real"]
		var/calls = entry_list["calls"]
		var/proc_name = entry_list["name"]
		total_self += self_time
		total_procs++

		// Category lookup — globally cached (proc paths never change)
		var/cat = categorize_profile_proc(proc_name)

		// Category aggregates from ALL procs (for accurate totals)
		cat_totals[cat] = (cat_totals[cat] || 0) + self_time
		cat_calls[cat] = (cat_calls[cat] || 0) + calls
		cat_count[cat] = (cat_count[cat] || 0) + 1

		// Per-category top 10 procs (no threshold — ensures every category has displayable data)
		var/list/cat_procs = cat_top_procs[cat]
		if(!cat_procs)
			cat_procs = list()
			cat_top_procs[cat] = cat_procs
		if(length(cat_procs) < 10)
			cat_procs += list(list("name" = proc_name, "self" = self_time, "total" = total_time, "real" = real_time, "calls" = calls, "cat" = cat))
		else
			// Replace minimum if this proc is larger
			var/min_idx = 1
			var/min_val = cat_procs[1]["self"]
			for(var/k in 2 to 10)
				if(cat_procs[k]["self"] < min_val)
					min_val = cat_procs[k]["self"]
					min_idx = k
			if(self_time > min_val)
				cat_procs[min_idx] = list("name" = proc_name, "self" = self_time, "total" = total_time, "real" = real_time, "calls" = calls, "cat" = cat)

		// Skip negligible procs for the top-N buffer
		if(self_time < 0.001)
			continue

		new_self_times[proc_name] = self_time

		// Bounded buffer: maintain top PROFILER_BUFFER_MAX entries by self time
		if(length(result) < PROFILER_BUFFER_MAX)
			result += list(list(
				"name" = proc_name,
				"self" = self_time,
				"total" = total_time,
				"real" = real_time,
				"calls" = calls,
				"avg" = round(self_time / max(calls, 1), 0.001),
				"cat" = cat,
			))
			if(self_time < min_self_in_buffer || min_self_in_buffer == 0)
				min_self_in_buffer = self_time
		else if(self_time > min_self_in_buffer)
			// Find and replace the minimum entry
			var/min_idx = 1
			var/min_val = result[1]["self"]
			for(var/k in 2 to PROFILER_BUFFER_MAX)
				if(result[k]["self"] < min_val)
					min_val = result[k]["self"]
					min_idx = k
			result[min_idx] = list(
				"name" = proc_name,
				"self" = self_time,
				"total" = total_time,
				"real" = real_time,
				"calls" = calls,
				"avg" = round(self_time / max(calls, 1), 0.001),
				"cat" = cat,
			)
			// Recompute min
			min_self_in_buffer = result[1]["self"]
			for(var/k in 2 to PROFILER_BUFFER_MAX)
				if(result[k]["self"] < min_self_in_buffer)
					min_self_in_buffer = result[k]["self"]

	// Finalize buffer entries: round values, compute self_pct and delta
	cached_total_self = total_self
	for(var/list/entry in result)
		entry["self"] = round(entry["self"], 0.001)
		entry["total"] = round(entry["total"], 0.001)
		entry["real"] = round(entry["real"], 0.001)
		entry["self_pct"] = total_self > 0 ? round((entry["self"] / total_self) * 100, 0.01) : 0
		if(length(previous_self_times))
			var/prev = previous_self_times[entry["name"]]
			entry["delta"] = isnum(prev) ? round(entry["self"] - prev, 0.01) : 0
		else
			entry["delta"] = 0
	previous_self_times = new_self_times

	// Build category results (already aggregated above)
	var/list/categories = list()
	for(var/cat in cat_totals)
		categories += list(list(
			"id" = cat,
			"name" = get_profiler_category_name(cat),
			"self_total" = round(cat_totals[cat], 0.01),
			"self_pct" = total_self > 0 ? round((cat_totals[cat] / total_self) * 100, 0.1) : 0,
			"calls" = cat_calls[cat],
			"proc_count" = cat_count[cat],
		))

	// Sort categories by self_total descending (typically ~15 categories, selection sort is fine)
	for(var/i in 1 to length(categories))
		var/max_idx = i
		for(var/j in (i + 1) to length(categories))
			if(categories[j]["self_total"] > categories[max_idx]["self_total"])
				max_idx = j
		if(max_idx != i)
			var/temp = categories[i]
			categories[i] = categories[max_idx]
			categories[max_idx] = temp
	cached_category_data = categories

	// Finalize per-category top procs: round values, add self_pct/delta, sort descending by self
	for(var/cat in cat_top_procs)
		var/list/procs = cat_top_procs[cat]
		for(var/list/entry in procs)
			entry["self"] = round(entry["self"], 0.001)
			entry["total"] = round(entry["total"], 0.001)
			entry["real"] = round(entry["real"], 0.001)
			entry["avg"] = round(entry["self"] / max(entry["calls"], 1), 0.001)
			entry["self_pct"] = total_self > 0 ? round((entry["self"] / total_self) * 100, 0.01) : 0
			entry["delta"] = 0
			if(length(previous_self_times))
				var/prev = previous_self_times[entry["name"]]
				if(isnum(prev))
					entry["delta"] = round(entry["self"] - prev, 0.01)
		// Sort by self descending (selection sort on <=10 items — negligible)
		for(var/i in 1 to length(procs))
			var/max_idx = i
			for(var/j in (i + 1) to length(procs))
				if(procs[j]["self"] > procs[max_idx]["self"])
					max_idx = j
			if(max_idx != i)
				var/temp = procs[i]
				procs[i] = procs[max_idx]
				procs[max_idx] = temp
	cached_category_procs = cat_top_procs

	debug_status = "OK: [length(result)]/[total_procs] процедур ([time2text(world.timeofday, "hh:mm:ss")])"
	cached_profile_data = result

/datum/server_profiler/proc/dump_enhanced_csv()
	var/list/lines = list()
	var/list/header = list("timestamp", "world_time", "cpu", "fps", "players", "instances", "tick_drift", "time_dilation", "tidi_fast", "tidi_avg", "tidi_slow", "map_tick")
	if(Master)
		for(var/datum/controller/subsystem/SS as anything in Master.subsystems)
			if(SS.flags & SS_NO_FIRE)
				continue
			header += "ss_[SS.name]_cost"
			header += "ss_[SS.name]_tick"
	lines += jointext(header, ",")

	var/list/row = list(
		time2text(world.timeofday, "hh:mm:ss"),
		"[world.time]",
		"[world.cpu]",
		"[world.fps]",
		"[GLOB.clients.len]",
		"[world.contents.len]",
		"[Master ? round(Master.tickdrift, 0.1) : 0]",
		"[round(SStime_track.time_dilation_current, 0.1)]",
		"[round(SStime_track.time_dilation_avg_fast, 0.1)]",
		"[round(SStime_track.time_dilation_avg, 0.1)]",
		"[round(SStime_track.time_dilation_avg_slow, 0.1)]",
		"[round(MAPTICK_LAST_INTERNAL_TICK_USAGE, 0.1)]",
	)
	if(Master)
		for(var/datum/controller/subsystem/SS as anything in Master.subsystems)
			if(SS.flags & SS_NO_FIRE)
				continue
			row += "[round(SS.cost, 0.01)]"
			row += "[round(SS.tick_usage, 0.01)]"
	lines += jointext(row, ",")

	var/filename = "[GLOB.log_directory]/profiler_snapshot_[time2text(world.timeofday, "hh-mm-ss")].csv"
	var/file_ref = file(filename)
	WRITE_FILE(file_ref, jointext(lines, "\n"))

/datum/server_profiler/proc/dump_proc_hotspots()
	if(!profiling_active)
		to_chat(owner?.mob, span_warning("Профилирование не активно. Запустите профилирование перед дампом."))
		return

	// Use global cached profile instead of independent fetch
	var/list/parsed = SSprofiler.get_cached_profile(force_refresh = TRUE)
	if(!length(parsed))
		return

	// Build list
	var/list/entries = list()
	for(var/list/entry in parsed)
		entries += list(list("name" = entry["name"], "self" = entry["self"], "total" = entry["total"], "real" = entry["real"], "calls" = entry["calls"]))

	// Partial selection sort by self time descending — top 20 only
	var/top_count = min(20, length(entries))
	for(var/i in 1 to top_count)
		var/max_idx = i
		for(var/j in (i + 1) to length(entries))
			if(entries[j]["self"] > entries[max_idx]["self"])
				max_idx = j
		if(max_idx != i)
			var/temp = entries[i]
			entries[i] = entries[max_idx]
			entries[max_idx] = temp

	// Separate profiler's own procs from real data
	var/list/profiler_own = list()
	var/list/real_entries = list()
	for(var/list/e in entries)
		if(findtext(e["name"], "/server_profiler") || findtext(e["name"], "/log_profiler_top_procs"))
			profiler_own += list(e)
		else
			real_entries += list(e)

	var/list/lines = list()
	lines += "=============================================================================================="
	lines += "=== PROFILER HOTSPOT DUMP [time2text(world.timeofday, "hh:mm:ss")] | world.time=[world.time] | cpu=[world.cpu]% | players=[GLOB.clients.len] ==="
	lines += "=============================================================================================="

	// === TOP PROCS (excluding profiler itself) ===
	var/real_top = min(25, length(real_entries))
	lines += ""
	lines += "--- Топ-[real_top] процедур по self time ---"
	for(var/i in 1 to real_top)
		var/list/e = real_entries[i]
		lines += "  [i]. [e["name"]] | self=[format_time(e["self"])] | total=[format_time(e["total"])] | calls=[e["calls"]] | avg=[format_time(e["self"] / max(e["calls"], 1))]"

	// Profiler's own overhead (separate section)
	if(length(profiler_own))
		lines += ""
		lines += "  (Собственная нагрузка профайлера — исключена из топа):"
		for(var/list/e in profiler_own)
			lines += "    [e["name"]] | self=[format_time(e["self"])] | calls=[e["calls"]]"

	// === TGUI BREAKDOWN ===
	lines += ""
	lines += "--- TGUI ([length(SStgui.open_uis)] открытых UI, SStgui cost=[round(SStgui.cost, 0.01)]мс, tick=[round(SStgui.tick_usage, 0.01)]%) ---"
	if(length(SStgui.open_uis))
		var/list/tgui_by_interface = list()
		for(var/datum/tgui/ui in SStgui.open_uis)
			var/iface_key = "[ui.interface] ([ui.src_object?.type])"
			tgui_by_interface[iface_key] = (tgui_by_interface[iface_key] || 0) + 1
		var/list/tgui_sorted = sort_assoc_by_value(tgui_by_interface)
		for(var/i in 1 to min(20, length(tgui_sorted)))
			var/key = tgui_sorted[i]
			lines += "  [tgui_by_interface[key]]x [key]"

		// Find ui_data AND ui_act procs in profile data
		lines += ""
		lines += "  Нагрузка от UI-процедур (из профайлера):"
		var/list/ui_procs = list()
		for(var/list/e in real_entries)
			if(findtext(e["name"], "/ui_data") || findtext(e["name"], "/ui_act") || findtext(e["name"], "/ui_interact") || findtext(e["name"], "/ui_static_data"))
				ui_procs += list(e)
		if(length(ui_procs))
			for(var/i in 1 to min(15, length(ui_procs)))
				var/list/e = ui_procs[i]
				lines += "    [e["name"]] | self=[format_time(e["self"])] | calls=[e["calls"]] | avg=[format_time(e["self"] / max(e["calls"], 1))]"
		else
			lines += "    (нет данных по UI-процедурам в профайлере)"
	else
		lines += "  (нет открытых интерфейсов)"

	// === SUBSYSTEMS ===
	lines += ""
	lines += "--- Стоимость подсистем (топ-15) ---"
	if(Master)
		var/list/ss_costs = list()
		for(var/datum/controller/subsystem/SS as anything in Master.subsystems)
			if(SS.flags & SS_NO_FIRE)
				continue
			ss_costs += list(list("name" = SS.name, "cost" = SS.cost, "tick_usage" = SS.tick_usage, "tick_overrun" = SS.tick_overrun, "times_fired" = SS.times_fired))
		var/ss_top = min(15, length(ss_costs))
		for(var/i in 1 to ss_top)
			var/max_idx = i
			for(var/j in (i + 1) to length(ss_costs))
				if(ss_costs[j]["cost"] > ss_costs[max_idx]["cost"])
					max_idx = j
			if(max_idx != i)
				var/temp = ss_costs[i]
				ss_costs[i] = ss_costs[max_idx]
				ss_costs[max_idx] = temp
		for(var/i in 1 to ss_top)
			var/list/ss = ss_costs[i]
			lines += "  [i]. [ss["name"]] | cost=[round(ss["cost"], 0.01)]мс | tick=[round(ss["tick_usage"], 0.01)]% | overrun=[round(ss["tick_overrun"], 0.01)]%"

	// === MACHINE TYPE BREAKDOWN ===
	lines += ""
	lines += "--- Машины (processing: [length(SSmachines.processing)], всего: [length(SSmachines.all_machines)], powernets: [length(SSmachines.powernets)]) ---"
	if(length(SSmachines.processing))
		var/list/machine_counts = list()
		for(var/obj/machinery/M as anything in SSmachines.processing)
			var/type_name = "[M.type]"
			machine_counts[type_name] = (machine_counts[type_name] || 0) + 1
		var/list/machine_sorted = sort_assoc_by_value(machine_counts)
		lines += "  Типы (топ-25 по количеству):"
		for(var/i in 1 to min(25, length(machine_sorted)))
			var/key = machine_sorted[i]
			lines += "    [machine_counts[key]]x [key]"

		// Find machine process() procs in profile data
		lines += ""
		lines += "  Нагрузка от process() машин (из профайлера):"
		var/list/machine_procs = list()
		for(var/list/e in real_entries)
			if(findtext(e["name"], "/obj/machinery") && findtext(e["name"], "/process"))
				machine_procs += list(e)
		if(length(machine_procs))
			for(var/i in 1 to min(15, length(machine_procs)))
				var/list/e = machine_procs[i]
				lines += "    [e["name"]] | self=[format_time(e["self"])] | calls=[e["calls"]] | avg=[format_time(e["self"] / max(e["calls"], 1))]"
		else
			lines += "    (нет данных по process() машин в профайлере)"

	// === MOB BREAKDOWN ===
	lines += ""
	lines += "--- Мобы (living: [length(GLOB.mob_living_list)]) ---"
	if(length(GLOB.mob_living_list))
		var/list/mob_counts = list()
		for(var/mob/living/M as anything in GLOB.mob_living_list)
			var/type_name = "[M.type]"
			mob_counts[type_name] = (mob_counts[type_name] || 0) + 1
		var/list/mob_sorted = sort_assoc_by_value(mob_counts)
		lines += "  Типы (топ-20 по количеству):"
		for(var/i in 1 to min(20, length(mob_sorted)))
			var/key = mob_sorted[i]
			lines += "    [mob_counts[key]]x [key]"

		// Mob Life() / process() from profiler
		lines += ""
		lines += "  Нагрузка от Life()/process() мобов (из профайлера):"
		var/list/mob_procs = list()
		for(var/list/e in real_entries)
			if(findtext(e["name"], "/mob/living") && (findtext(e["name"], "/Life") || findtext(e["name"], "/process")))
				mob_procs += list(e)
		if(length(mob_procs))
			for(var/i in 1 to min(10, length(mob_procs)))
				var/list/e = mob_procs[i]
				lines += "    [e["name"]] | self=[format_time(e["self"])] | calls=[e["calls"]] | avg=[format_time(e["self"] / max(e["calls"], 1))]"
		else
			lines += "    (нет данных)"

	// === SSobj / SSfastprocess TYPE BREAKDOWN ===
	lines += ""
	lines += "--- SSobj (processing: [length(SSobj.processing)]) ---"
	if(length(SSobj.processing))
		var/list/obj_counts = list()
		for(var/datum/D as anything in SSobj.processing)
			var/type_name = "[D.type]"
			obj_counts[type_name] = (obj_counts[type_name] || 0) + 1
		var/list/obj_sorted = sort_assoc_by_value(obj_counts)
		for(var/i in 1 to min(15, length(obj_sorted)))
			var/key = obj_sorted[i]
			lines += "  [obj_counts[key]]x [key]"
	lines += ""
	lines += "--- SSfastprocess (processing: [length(SSfastprocess.processing)]) ---"
	if(length(SSfastprocess.processing))
		var/list/fast_counts = list()
		for(var/datum/D as anything in SSfastprocess.processing)
			var/type_name = "[D.type]"
			fast_counts[type_name] = (fast_counts[type_name] || 0) + 1
		var/list/fast_sorted = sort_assoc_by_value(fast_counts)
		for(var/i in 1 to min(15, length(fast_sorted)))
			var/key = fast_sorted[i]
			lines += "  [fast_counts[key]]x [key]"

	// === ATMOS BREAKDOWN ===
	lines += ""
	lines += "--- Атмосфера (SSair, cost=[round(SSair.cost, 0.01)]мс) ---"
	lines += "  cost_turfs=[round(SSair.cost_turfs, 0.01)]мс | cost_equalize=[round(SSair.cost_equalize, 0.01)]мс | cost_groups=[round(SSair.cost_groups, 0.01)]мс"
	lines += "  cost_highpressure=[round(SSair.cost_highpressure, 0.01)]мс | cost_hotspots=[round(SSair.cost_hotspots, 0.01)]мс | cost_superconductivity=[round(SSair.cost_superconductivity, 0.01)]мс"
	lines += "  cost_pipenets=[round(SSair.cost_pipenets, 0.01)]мс | cost_rebuilds=[round(SSair.cost_rebuilds, 0.01)]мс | cost_post_process=[round(SSair.cost_post_process, 0.01)]мс"
	lines += "  networks=[length(SSair.networks)] | hotspots=[length(SSair.hotspots)] | high_pressure_delta=[length(SSair.high_pressure_delta)] | atmos_machinery=[length(SSair.atmos_machinery)]"
	lines += "  gas_mixes=[SSair.get_amt_gas_mixes()] / [SSair.get_max_gas_mixes()] allocated"

	// === PROCESSING QUEUES ===
	lines += ""
	lines += "--- Очереди обработки ---"
	lines += "  SSmachines.processing: [length(SSmachines.processing)]"
	lines += "  SSmobs (GLOB.mob_living_list): [length(GLOB.mob_living_list)]"
	lines += "  SSprocessing: [length(SSprocessing.processing)]"
	lines += "  SSfastprocess: [length(SSfastprocess.processing)]"
	lines += "  SSobj: [length(SSobj.processing)]"
	lines += "  SSchemistry: [length(SSchemistry.processing)]"
	lines += "  SSstatus_effects: [length(SSstatus_effects.processing)]"
	lines += "  SStimer.timer_id_dict: [length(SStimer.timer_id_dict)]"

	// === GARBAGE COLLECTOR ===
	lines += ""
	lines += "--- Сборщик мусора (SSgarbage) ---"
	lines += "  totalgcs=[SSgarbage.totalgcs] | totaldels=[SSgarbage.totaldels] | gc_ratio=[SSgarbage.totalgcs ? round(SSgarbage.totalgcs / max(SSgarbage.totalgcs + SSgarbage.totaldels, 1) * 100, 0.1) : 0]%"
	lines += "  delslasttick=[SSgarbage.delslasttick] | gcedlasttick=[SSgarbage.gcedlasttick]"
	lines += "  highest_del=[SSgarbage.highest_del_ms]мс ([SSgarbage.highest_del_type_string])"
	if(length(SSgarbage.queues))
		var/list/queue_info = list()
		for(var/i in 1 to length(SSgarbage.queues))
			queue_info += "Q[i]=[length(SSgarbage.queues[i])]"
		lines += "  Очереди: [jointext(queue_info, " | ")]"

	// === GENERAL STATS ===
	lines += ""
	lines += "--- Общие показатели ---"
	lines += "  world.contents: [world.contents.len]"
	lines += "  world.cpu: [world.cpu]% | world.fps: [world.fps] | tick_lag: [world.tick_lag]"
	lines += "  time_dilation: [round(SStime_track.time_dilation_current, 0.1)]% | avg: [round(SStime_track.time_dilation_avg, 0.1)]%"
	lines += "  map_tick: [round(MAPTICK_LAST_INTERNAL_TICK_USAGE, 0.1)]%"
	if(Master)
		lines += "  MC iteration: [Master.iteration] | tickdrift: [round(Master.tickdrift, 0.1)]"
	lines += ""

	var/filename = "[GLOB.log_directory]/profiler_hotspots.log"
	var/file_ref = file(filename)
	WRITE_FILE(file_ref, jointext(lines, "\n"))

	log_admin("Server Profiler: записан дамп горячих точек в profiler_hotspots.log")

/// Helper: format time value smartly — мс for large, мкс for small
/datum/server_profiler/proc/format_time(value)
	if(!isnum(value) || value == 0)
		return "0мс"
	if(value >= 0.01)
		return "[round(value, 0.01)]мс"
	// Show in microseconds for sub-0.01ms values
	return "[round(value * 1000, 0.01)]мкс"

/// Helper: sort assoc list keys by their numeric values descending. Returns sorted list of keys.
/datum/server_profiler/proc/sort_assoc_by_value(list/assoc)
	var/list/keys = list()
	for(var/key in assoc)
		keys += key
	// Selection sort descending by value
	for(var/i in 1 to length(keys))
		var/max_idx = i
		for(var/j in (i + 1) to length(keys))
			if(assoc[keys[j]] > assoc[keys[max_idx]])
				max_idx = j
		if(max_idx != i)
			var/temp = keys[i]
			keys[i] = keys[max_idx]
			keys[max_idx] = temp
	return keys

// Admin verb
/client/proc/open_server_profiler()
	set category = "Debug"
	set name = "Server Profiler"

	if(!check_rights(R_ADMIN))
		return

	var/datum/server_profiler/profiler = new(src)
	profiler.ui_interact(mob)
	SSblackbox.record_feedback("tally", "admin_verb", 1, "Server Profiler")
	log_admin("[key_name(src)] opened Server Profiler panel.")
