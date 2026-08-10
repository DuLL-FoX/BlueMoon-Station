/// Клиент, подключившийся только что, ещё распаковывает ресурсы: его первые ответы меряют
/// выдачу, а не канал.
#define PING_BUFFER_TIME 25
/// Клиента, не трогавшего ввод пять минут, спрашивать не о чем: сэмпл всё равно уйдёт в
/// протухшие, а winset разбудит скин впустую.
#define PING_IDLE_SKIP_TIME 3000

/**
 * # Нативный пинг
 *
 * Проба ездит не по сокету, а по командному каналу скина: DreamDaemon отдаёт winset с двумя
 * метками времени, DreamSeeker исполняет команду и возвращает скрытый верб `.update_ping`.
 * Обратный ход упирается в то, что верб не может исполниться, пока интерпретатор занят DM:
 * BYOND добирается до входящего сообщения только когда МК досчитает свой тик и уснёт.
 *
 * Поэтому вся работа, которую МК успевает сделать **после** отправки, приезжает игроку
 * внутри его же пинга. Пока проба уходила из SSserver_maint (приоритет 10, почти конец
 * NORMAL-секции), в замер попадала целиком фоновая секция очереди - SSair, Garbage,
 * Processing, Adjacency, Parallax, AI-контроллеры. На локальном сервере это давало ровно
 * один tick_lag: в логах за август 33 из 78 спайков стояли точно на 50.00мс, а между 28 и
 * 50мс не было ни одного сэмпла - частокол на длине тика вместо распределения по каналу.
 *
 * Отсюда собственная подсистема с минимальным приоритетом и SS_BACKGROUND: очередь МК
 * сортируется по убыванию приоритета, а фоновая секция идёт после обычной, так что эта
 * подсистема гарантированно последняя и хвоста после неё не остаётся. Заодно последний
 * узел очереди получает весь остаток тика (`current_tick_budget` к этому моменту равен его
 * же приоритету), так что MC_TICK_CHECK внутри цикла не режет рассылку по одному клиенту.
 */
SUBSYSTEM_DEF(ping)
	name = "Client Ping"
	wait = 18
	priority = FIRE_PRIORITY_PING
	flags = SS_BACKGROUND | SS_NO_INIT
	runlevels = RUNLEVEL_LOBBY | RUNLEVELS_DEFAULT
	var/list/currentrun

/datum/controller/subsystem/ping/fire(resumed = FALSE)
	if(!resumed)
		src.currentrun = GLOB.clients.Copy()

	var/list/currentrun = src.currentrun
	while(length(currentrun))
		var/client/target = currentrun[length(currentrun)]
		currentrun.len--
		if(!target)
			continue
		if(world.time - target.connection_time < PING_BUFFER_TIME)
			continue
		if(target.inactivity >= PING_IDLE_SKIP_TIME)
			continue
		target.ping_sequence_sent++
		winset(target, null, "command=.update_ping+[ping_wire_num(world.time + world.tick_lag * TICK_USAGE_REAL / 100)]+[ping_wire_num(REALTIMEOFDAY)]+[target.ping_sequence_sent]")
		MC_TICK_CHECK

#undef PING_BUFFER_TIME
#undef PING_IDLE_SKIP_TIME
