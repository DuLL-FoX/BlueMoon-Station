// Система сохранения татуировок между раундами
// Татуировки сохраняются автоматически в конце раунда (не требуется эвакуация)
// Загружаются при спавне персонажа

// Формат сохранения татуировок
#define TATTOO_SAVE_VERS 1
#define TATTOO_SAVE_ZONE 2
#define TATTOO_SAVE_TEXT 3
#define TATTOO_SAVE_LENGTH 3

#define TATTOO_CURRENT_VERSION 1

// Расширение preferences для хранения татуировок
/datum/preferences
	/// Включены ли постоянные татуировки
	var/persistent_tattoos = TRUE
	/// Сохранённые татуировки персонажа (формат: "VERSION|ZONE|TEXT;VERSION|ZONE|TEXT;...")
	var/tattoos_string = ""

// Загрузка настроек татуировок
/datum/preferences/proc/load_tattoo_prefs(savefile/S)
	S["persistent_tattoos"] >> persistent_tattoos
	S["tattoos_string"] >> tattoos_string

	persistent_tattoos = sanitize_integer(persistent_tattoos, 0, 1, TRUE)
	tattoos_string = sanitize_text(tattoos_string)

// Сохранение настроек татуировок
/datum/preferences/proc/save_tattoo_prefs(savefile/S)
	WRITE_FILE(S["persistent_tattoos"], persistent_tattoos)
	WRITE_FILE(S["tattoos_string"], tattoos_string)

// Форматирование татуировок для сохранения
/mob/living/carbon/human/proc/format_tattoos()
	var/tattoos = ""
	for(var/obj/item/bodypart/BP as anything in bodyparts)
		if(BP.tattoo_text && BP.tattoo_text != "")
			tattoos += "[TATTOO_CURRENT_VERSION]|[BP.body_zone]|[BP.tattoo_text];"
	return tattoos

// Загрузка одной татуировки из сохранённых данных
/mob/living/carbon/human/proc/load_tattoo(tattoo_line)
	var/list/tattoo_data = splittext(tattoo_line, "|")
	if(LAZYLEN(tattoo_data) != TATTOO_SAVE_LENGTH)
		return FALSE // невалидные данные

	var/version = text2num(tattoo_data[TATTOO_SAVE_VERS])
	if(!version || version < TATTOO_CURRENT_VERSION)
		return FALSE // устаревший формат

	var/zone = tattoo_data[TATTOO_SAVE_ZONE]
	var/text = tattoo_data[TATTOO_SAVE_TEXT]

	var/obj/item/bodypart/the_part = get_bodypart(zone)
	if(!the_part)
		return FALSE // нет такой части тела

	// Добавляем татуировку
	if(the_part.tattoo_text)
		the_part.tattoo_text += "; " + text
	else
		the_part.tattoo_text = text

	return TRUE

// Хук для загрузки татуировок при создании персонажа
/datum/preferences/proc/apply_tattoos_to_human(mob/living/carbon/human/H)
	if(!persistent_tattoos || !tattoos_string)
		return

	var/valid_tattoos = ""
	for(var/tattoo_line in splittext(tattoos_string, ";"))
		if(!tattoo_line || tattoo_line == "")
			continue
		if(H.load_tattoo(tattoo_line))
			valid_tattoos += "[tattoo_line];"

	// Обновляем сохранённые данные (удаляем невалидные)
	tattoos_string = valid_tattoos

// Хук для сохранения татуировок в конце раунда
/datum/controller/subsystem/persistence/proc/SaveTattoos()
	for(var/ckey in GLOB.joined_player_list)
		var/mob/living/carbon/human/ending_human = get_mob_by_ckey(ckey)
		if(!istype(ending_human) || !ending_human.mind || !ending_human.client || !ending_human.client.prefs)
			continue

		if(!ending_human.client.prefs.persistent_tattoos)
			continue

		var/mob/living/carbon/human/original_human = ending_human.mind.original_character.resolve()

		// Для татуировок не требуется выживание или эвакуация - сохраняем всегда
		// если это оригинальный персонаж
		if(!original_human || !(original_human == ending_human))
			continue

		ending_human.client.prefs.tattoos_string = ending_human.format_tattoos()
		ending_human.client.prefs.save_character()
