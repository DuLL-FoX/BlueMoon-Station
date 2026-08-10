
/client
		//////////////////////
		//BLACK MAGIC THINGS//
		//////////////////////
	parent_type = /datum

		///////////////
		// Rendering //
		///////////////

	/// Click catcher
	var/atom/movable/screen/click_catcher/click_catcher
	/// Parallax holder
	var/datum/parallax_holder/parallax_holder

		////////////////
		//ADMIN THINGS//
		////////////////
	/// hides the byond verb panel as we use our own custom version
	show_verb_panel = FALSE
	///Contains admin info. Null if client is not an admin.
	var/datum/admins/holder = null
	/// TRUE while blocking input() modal open
	var/reply_modal_open = FALSE
	/// If TRUE, this admin receives GC leak notifications (warnfail/softcheck alerts). Toggle via GC Health Panel.
	var/gc_leak_notify = FALSE
	var/datum/click_intercept = null // Needs to implement InterceptClickOn(user,params,atom) proc
	///Time when the click was intercepted
	var/click_intercept_time = 0
	var/AI_Interact		= 0

	var/jobbancache = null //Used to cache this client's jobbans to save on DB queries
	var/last_message	= "" //Contains the last message sent by this client - used to protect against copy-paste spamming.
	var/last_message_count = 0 //contins a number of how many times a message identical to last_message was sent.
	///How many messages sent in the last 10 seconds
	var/total_message_count = 0
	///Next tick to reset the total message counter
	var/total_count_reset = 0
	var/ircreplyamount = 0
	/// last time they tried to do an autobunker auth
	var/autobunker_last_try = 0

		/////////
		//OTHER//
		/////////
	var/datum/preferences/prefs = null
	/// The client's UI DPI multiplier reported by BYOND. 1 equals 100% Windows scaling.
	var/window_scaling = 1
	/// Current DPI acquisition retry count for delayed post-login reads.
	var/window_scaling_retry_count = 0
	var/last_turn = 0
	var/move_delay = 0
	var/last_move = 0
	/// Расписание, каким его оставил последний шаг. Если move_delay уехал от
	/// этого значения - его переставил кто-то ещё (захват, отдача, админ), и
	/// перебазировать его на смене скорости нельзя. См. movement_reschedule_step().
	var/last_step_target = 0
	/// Цена последнего шага, уже кратная тику. Нужна, чтобы на смене скорости
	/// сдвинуть расписание ровно на разницу цен.
	var/last_step_cost = 0
	/// Был ли последний шаг диагональным. Диагональ стоит SQRT_2, и пересчёт
	/// цены обязан знать, по какой ставке шаг оплачивали.
	var/last_step_diagonal = FALSE
	var/area			= null

	/// Timers are now handled by clients, not by doing a mess on the item and multiple people overwriting a single timer on the object, have fun.
	var/tip_timer = null

	/// Last time we Click()ed. No clicking twice in one tick!
	var/last_click = 0

		///////////////
		//SOUND STUFF//
		///////////////
	var/ambience_playing= null
	var/played			= 0
		////////////
		//SECURITY//
		////////////
	// comment out the line below when debugging locally to enable the options & messages menu
	control_freak = 1

		////////////////////////////////////
		//things that require the database//
		////////////////////////////////////
	var/player_age = -1	//Used to determine how old the account is - in days.
	var/player_join_date = null //Date that this account was first seen in the server
	var/related_accounts_ip = "Requires database"	//So admins know why it isn't working - Used to determine what other accounts previously logged in from this ip
	var/related_accounts_cid = "Requires database"	//So admins know why it isn't working - Used to determine what other accounts previously logged in from this computer id
	var/account_join_date = null	//Date of byond account creation in ISO 8601 format
	var/account_age = -1	//Age of byond account in days

	preload_rsc = PRELOAD_RSC

	var/atom/movable/screen/click_catcher/void
	var/atom/movable/screen/click_catcher/void_right
	var/atom/movable/screen/click_catcher/void_bottom

	//These two vars are used to make a special mouse cursor, with a unique icon for clicking
	var/mouse_up_icon = null
	var/mouse_down_icon = null
	///used to override the mouse cursor so it doesnt get reset
	var/mouse_override_icon = null

	var/ip_intel = "Disabled"

	//datum that controls the displaying and hiding of tooltips
	var/datum/tooltip/tooltips

	var/lastping = 0
	var/avgping = 0
	var/lastping_rtt = 0
	var/avgping_rtt
	var/lastping_rtt_raw = 0
	var/avgping_rtt_raw
	var/lastping_tick = 0
	var/lastping_server = 0
	/// world.time последнего обновления ping-значений. Сводка по миру обязана отсеивать
	/// протухшие сэмплы, иначе один подвисший клиент навсегда задирает max и среднее.
	var/lastping_at = 0
	var/avgping_server
	var/avgping_jitter
	var/ping_updated = FALSE
	/// Монотонные номера нативных ping-команд: пропуски и перестановка показывают
	/// очередь DreamSeeker, чего один timestamp определить не может.
	var/ping_sequence_sent = 0
	var/ping_sequence_received = 0
	/// Сколько ответов уже принято. Отличает «предыдущего сэмпла не было» от «предыдущий
	/// был нулевым»: без этого джиттер первого замера равнялся всему первому пингу.
	var/ping_replies_received = 0
	/// Стенные часы последнего ответа нужны для интервала между ответами. world.time
	/// продолжает идти во время клиентского ожидания и скрывает такую паузу.
	var/lastping_realtimeofday = 0
	/// world.time последнего подробного native_ping_spike; null допускает первый отчёт.
	var/last_ping_latency_report_at
	/// Последний медленный round-trip до нативного скина (winget/winexists).
	var/last_skin_latency_at = 0
	var/last_skin_latency_kind
	var/last_skin_latency_ms = 0
	var/last_skin_latency_detail
	/// Последний синхронно дорогой /client/Topic этого клиента.
	var/last_slow_topic_at = 0
	var/last_slow_topic_context
	var/last_slow_topic_ms = 0
	/// Последняя задержка, которую независимо увидел statbrowser или tgui-panel.
	var/last_browser_latency_at = 0
	var/last_browser_latency_source
	var/last_browser_latency_ms = 0
	var/last_browser_latency_hidden = FALSE
	var/last_browser_latency_focused = FALSE
	/// Источник -> world.time последнего принятого отчёта; отдельные WebView не
	/// заглушают друг друга, но один источник не может заспамить лог.
	var/list/browser_latency_report_times = list()
	/// Докуда дошла выдача ресурсов этому клиенту, см. CLIENT_RESOURCE_STAGE_*. Нужен
	/// строке Logout: BYOND про обрыв говорит только "code 0: no/unknown reason".
	var/resource_stage = CLIENT_RESOURCE_STAGE_CONNECTED
	/// "этап" -> REALTIMEOFDAY входа в него. Ключ текстовый: ассоциативный список с
	/// числовым ключом BYOND читает как индекс. Счётчики этапов говорят, ГДЕ рвётся,
	/// а эти метки - сколько выдача стоит тем, кто дошёл; считаем по живым клиентам.
	var/list/resource_stage_times = list()
	/// Independent per-connection browser/resource lifecycle. resource_stage and the
	/// older booleans above remain compatibility projections for logs and callers.
	var/datum/client_resource_session/resource_session
	/// TRUE after validated browser devicePixelRatio telemetry was applied. Login DPI
	/// timers use this to avoid a redundant blocking native winget.
	var/dpi_telemetry_received = FALSE
	/// Адрес внешнего зеркала .rsc, назначенный этому клиенту. null - раздача идёт
	/// с DreamDaemon (внешних адресов нет либо выдача выключена).
	var/rsc_source_url
	/// TRUE после того, как панели отправили клиентскую пробу внешних адресов. Проба
	/// одноразовая: набор адресов за подключение не меняется.
	var/external_delivery_probe_sent = FALSE
	/// TRUE после первого принятого отчёта пробы. Счётчики раунда считают клиентов,
	/// а не отчёты, и повтор не должен сдвигать долю.
	var/external_delivery_probe_reported = FALSE
	/// TRUE, если окно статбраузера открывалось адресом наружу (webroot-транспорт).
	/// Запоминаем в момент выдачи: к проверке транспорт мог уже сорваться, а клиент
	/// всё равно держит выданный ему http-адрес.
	var/statbrowser_served_externally = FALSE
	/// TRUE после того, как статбраузер этому клиенту переоткрыли локально.
	var/statbrowser_local_fallback = FALSE
	/// Сколько раз игрок просил перезагрузить статбраузер ссылкой из чата.
	var/statbrowser_reload_attempts = 0
	/// Сколько раз подряд автоматическую подгонку вьюпорта уже отложили, потому что скин
	/// не отвечал. Сбрасывается, как только подгонка состоялась.
	var/fit_viewport_defers = 0
	var/list/ping_rtt_window = list()
	/// Incrementally maintained sorted mirror of ping_rtt_window, see rtt_window_push()
	var/list/ping_rtt_sorted = list()
	var/connection_time //world.time they connected
	var/connection_realtime //world.realtime they connected
	var/connection_timeofday //world.timeofday they connected
	/// REALTIMEOFDAY подключения. Именно он, а не connection_realtime: world.realtime это
	/// децисекунды с 2000 года, к 2026-му уже ~8.3e9, и шаг 32-битного float на этой величине
	/// равен 512 дс. Разность двух world.realtime поэтому квантуется по 51.2 СЕКУНДЫ - в
	/// раунде 9837 поле "жил" выдало ровно 0 / 51.2 / 102.4 / 153.6 и не несло информации.
	/// REALTIMEOFDAY не превышает 1.73e6, шаг там ~12 мс, и он же переживает полночь.
	var/connection_realtimeofday
	/// Почему соединение закрыл САМ сервер. null = рвал клиент или сеть между нами.
	/// Уходит в строку Logout: без неё в логах наш кик неотличим от обрыва канала.
	var/disconnect_reason
	/// Какой это по счёту вход этого ckey за раунд. Циклический реконнект видно сразу.
	var/round_login_index = 1

	var/inprefs = FALSE
	var/list/topiclimiter

	///Used for limiting the rate of clicks sends by the client to avoid abuse
	var/list/clicklimiter

	///lazy list of all credit object bound to this client
	var/list/credits

	var/datum/player_details/player_details //these persist between logins/logouts during the same round.

	var/list/char_render_holders			//Should only be a key-value list of north/south/east/west = atom/movable/screen.

	/// Last time they used fix macros
	var/last_macro_fix = 0
	/// Keys currently held
	var/list/keys_held = list()
	/// Last initial/repeated movement KeyDown. Native +REP and TGUI repeats lease held movement;
	/// if focus loss eats KeyUp and the repeats stop, SSinput releases only movement keys.
	var/last_movement_key_repeat
	/// These next two vars are to apply movement for keypresses and releases made while move delayed.
	/// Because discarding that input makes the game less responsive.
 	/// On next move, add this dir to the move that would otherwise be done
	var/next_move_dir_add
 	/// On next move, subtract this dir from the move that would otherwise be done
	var/next_move_dir_sub
	/// Amount of keydowns in the last keysend checking interval
	var/client_keysend_amount = 0
	/// World tick time where client_keysend_amount will reset
	var/next_keysend_reset = 0
	/// World tick time where keysend_tripped will reset back to false
	var/next_keysend_trip_reset = 0
	/// When set to true, user will be autokicked if they trip the keysends in a second limit again
	var/keysend_tripped = FALSE
	/// custom movement keys for this client
	var/list/movement_keys = list()

	///Autoclick list of two elements, first being the clicked thing, second being the parameters.
	var/list/atom/selected_target[2]
	///Autoclick variable referencing the associated item.
	var/obj/item/active_mousedown_item = null
	///Used in MouseDrag to preserve the original mouse click parameters
	var/mouseParams = ""
	///Used in MouseDrag to preserve the last mouse-entered location. Weakref
	var/datum/weakref/mouse_location_ref = null
	///Used in MouseDrag to preserve the last mouse-entered object. Weakref
	var/datum/weakref/mouse_object_ref
	var/mouse_control_object

	/// Messages currently seen by this client
	var/list/seen_messages
	/// viewsize datum for holding our view size
	var/datum/view_data/view_size

	/// our current tab
	var/stat_tab

	/// whether our browser is ready or not yet
	var/statbrowser_ready = FALSE

	/// whether remove_admin_tabs has been sent (avoids redundant output() every cycle)
	var/admin_tabs_cleared = FALSE

	/// turf currently watched for listed turf dirtiness signals
	var/turf/listed_turf_watched
	/// whether the listed turf needs a new visibility snapshot
	var/listed_turf_dirty = FALSE
	/// world.time when the listed turf was last marked dirty by a signal — debounces churn on busy turfs
	var/listed_turf_dirty_at = 0
	/// whether the listed turf should force-refresh icons on the next snapshot
	var/listed_turf_icon_refresh_pending = FALSE
	/// world.time when the listed turf list was last refreshed
	var/listed_turf_last_refresh = 0
	/// world.time when the listed turf icons were last refreshed
	var/listed_turf_last_icon_refresh = 0
	/// last eye turf ref used to build the listed turf snapshot
	var/listed_turf_eye_ref
	/// cached turf REF for statpanel — skip re-rendering if same turf
	var/cached_turf_ref
	/// cached encoded turf data for statpanel
	var/cached_turf_encoded
	/// tracks which icon REFs have been sent to this client's statbrowser (REF -> icon_url)
	var/list/statpanel_sent_icons = list()
	/// per-section dirty cache: last-sent encoded payload by channel name (status/spells/voting/tickets/listedturf)
	/// Suppresses identical re-sends without re-running expensive renderers — DM-side dirty checking.
	var/list/statpanel_last_sent = list()
	/// cached MC iteration counter last sent to this client (suppresses stringify-hash work on JS side)
	var/statpanel_last_mc_iter = -1
	/// JSON-encoded global server payload version (echoed in update_ping handshake) — bumps when DM payload shape changes
	var/statpanel_protocol_acked = FALSE

	/// list of all tabs
	var/list/panel_tabs = list()

	/// list of tabs containing spells and abilities
	var/list/spell_tabs = list()
	/// list of tabs containing verbs
	var/list/verb_tabs = list()

	var/stat_vote_sent_null = FALSE
	///A lazy list of atoms we've examined in the last EXAMINE_MORE_TIME (default 1.5) seconds, so that we will call [atom/proc/examine_more()] instead of [atom/proc/examine()] on them when examining
	var/list/recent_examines
	///When was the last time we warned them about not cryoing without an ahelp, set to -5 minutes so that rounstart cryo still warns
	var/cryo_warned = -5 MINUTES

	/**
	 * Assoc list with all the active maps - when a screen obj is added to
	 * a map, it's put in here as well.
	 *
	 * Format: list(<mapname> = list(/atom/movable/screen))
	 */
	var/list/screen_maps = list()

	// List of all asset filenames sent to this client by the asset cache, along with their assoicated md5s
	var/list/sent_assets = list()
	/// List of all completed blocking send jobs awaiting acknowledgement by send_asset
	var/list/completed_asset_jobs = list()
	/// Last asset send job id.
	var/last_asset_job = 0
	var/last_completed_asset_job = 0

	//world.time of when the crew manifest can be accessed
	var/crew_manifest_delay

	/// Should go in persistent round player data sometime. This tracks what items have already warned the user on pickup that they can block/parry.
	var/list/block_parry_hinted = list()
	/// moused over objects, currently capped at 7. this is awful, and should be replaced with a component to track it using signals for parrying at some point.
	var/list/moused_over_objects = list()

	/// AFK tracking
	var/last_activity = 0

	///Are we locking our movement input?
	var/movement_locked = FALSE

	/// The next point in time at which the client is allowed to send a mousemove() or mousedrag()
	COOLDOWN_DECLARE(next_mousemove)
	COOLDOWN_DECLARE(next_mousedrag)

	/// Cooldown for IC chat messages while SSlag_switch SLOWMODE_SAY is active
	COOLDOWN_DECLARE(say_slowmode)
