/// Титульный экран попадает в dyn.rsc и качается каждым клиентом ещё до того,
/// как у него появится интерфейс, поэтому его размер платится на каждом входе.
/// Всё, что тяжелее этого, - почти наверняка неужатая гифка, а не осознанный
/// выбор: полноэкранный сплэш укладывается в считанные сотни килобайт.
#define TITLE_SCREEN_SIZE_BUDGET (4 * 1024 * 1024)

SUBSYSTEM_DEF(title)
	name = "Title Screen"
	flags = SS_NO_FIRE
	init_order = INIT_ORDER_TITLE

	var/file_path
	var/icon/icon
	var/icon/previous_icon
	var/turf/closed/indestructible/splashscreen/splash_turf
	var/sound_path

/datum/controller/subsystem/title/Initialize()
	if(file_path && icon)
		return

	if(fexists("data/previous_title.dat"))
		var/previous_path = file2text("data/previous_title.dat")
		if(istext(previous_path))
			previous_icon = new(previous_icon)
	fdel("data/previous_title.dat")

	var/list/provisional_title_screens = flist("[global.config.directory]/title_screens/images/")
	var/list/title_screens = list()
	var/use_rare_screens = prob(1)

	SSmapping.HACK_LoadMapConfig()
	for(var/S in provisional_title_screens)
		var/list/L = splittext(S,"+")
		if(L.len == 1 && L[1] != "exclude" && L[1] != "blank.png")
			title_screens += S
		else if(L.len > 1)
			if((use_rare_screens && lowertext(L[1]) == "rare") || (lowertext(L[1]) == lowertext(SSmapping.config.map_name)))
				title_screens += S
			else if(findtext(L[2], "{") && findtext(L[2], "}"))
				title_screens += S

	title_screens = discard_oversized_title_screens(title_screens)

	if(length(title_screens))
		file_path = "[global.config.directory]/title_screens/images/[pick(title_screens)]"

	if(!file_path)
		file_path = "icons/runtime/default_title.dmi"

	ASSERT(fexists(file_path))

	// Размер печатаем человекочитаемым: интерполяция числа >= 1e6 даёт шесть значащих
	// цифр, и четырёхмегабайтный экран уезжал в лог как 4.19430e+006.
	log_world("[name]: [file_path] ([personal_music_box_size_text(length(file(file_path)))]) уходит каждому клиенту через dyn.rsc.")
	icon = new(fcopy_rsc(file_path))

	// Check for a corresponding sound file
	var/list/L = splittext(file_path, "+")
	if(L.len > 1)
		var/sound_suffix = replacetext(L[2], ".dmi", "")
		var/sound_file = "[global.config.directory]/title_music/sounds/[sound_suffix].ogg"
		if(fexists(sound_file))
			sound_path = sound_file
	else
		sound_path = null

	if(splash_turf)
		splash_turf.icon = icon
		splash_turf.handle_generic_titlescreen_sizes()

	return SS_INIT_SUCCESS

/// Убирает из выборки экраны, которые дороже, чем стоит вход в игру. Возвращает
/// отфильтрованный список; если пригодных не осталось, вызывающий откатится на
/// icons/runtime/default_title.dmi вместо того, чтобы раздать многомегабайтную
/// картинку всем подключающимся.
/datum/controller/subsystem/title/proc/discard_oversized_title_screens(list/title_screens)
	var/list/oversized = list()
	for(var/screen_name in title_screens)
		var/screen_path = "[global.config.directory]/title_screens/images/[screen_name]"
		var/screen_size = length(file(screen_path))
		if(screen_size > TITLE_SCREEN_SIZE_BUDGET)
			oversized[screen_name] = screen_size
	if(!length(oversized))
		return title_screens

	var/list/allowed = title_screens.Copy()
	for(var/screen_name in oversized)
		log_world("[name]: [screen_name] пропущен: [personal_music_box_size_text(oversized[screen_name])] при бюджете [personal_music_box_size_text(TITLE_SCREEN_SIZE_BUDGET)]. \
			Титульный экран качает каждый клиент - пережмите файл или уберите его из config/title_screens/images/.")
		allowed -= screen_name
	return allowed

/datum/controller/subsystem/title/vv_edit_var(var_name, var_value)
	. = ..()
	if(.)
		switch(var_name)
			if(NAMEOF(src, icon))
				if(splash_turf)
					splash_turf.icon = icon

/datum/controller/subsystem/title/Shutdown()
	if(file_path)
		var/F = file("data/previous_title.dat")
		WRITE_FILE(F, file_path)

	for(var/thing in GLOB.clients)
		if(!thing)
			continue
		var/atom/movable/screen/splash/S = new(null, thing, FALSE)
		S.Fade(FALSE,FALSE)

	// Save the sound path
	if(sound_path)
		var/F = file("data/previous_title_sound.dat")
		WRITE_FILE(F, sound_path)

/datum/controller/subsystem/title/Recover()
	icon = SStitle.icon
	splash_turf = SStitle.splash_turf
	file_path = SStitle.file_path
	previous_icon = SStitle.previous_icon

	// Recover the sound path
	if(fexists("data/previous_title_sound.dat"))
		sound_path = file2text("data/previous_title_sound.dat")

#undef TITLE_SCREEN_SIZE_BUDGET
