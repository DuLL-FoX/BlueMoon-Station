// Отображение татуировок при осмотре персонажа
// Татуировки видны только на открытых частях тела (не закрытых одеждой)

// Хук для отображения татуировок - вызывается в examine.dm
// Добавляем сигнал для модульного расширения examine

/mob/living/carbon/human/proc/get_tattoo_examine_text()
	var/tattoo_text_output = ""
	var/list/items_on_self = get_equipped_items()

	for(var/obj/item/bodypart/BP as anything in bodyparts)
		if(!BP.tattoo_text || BP.tattoo_text == "")
			continue

		// Проверяем видимость части тела
		var/covered_area = zone2body_parts_covered_complicated(BP.body_zone)
		if(!covered_area)
			covered_area = CHEST

		var/show_tattoo = TRUE
		for(var/obj/item/worn_clothes in items_on_self)
			if(worn_clothes.body_parts_covered & covered_area)
				show_tattoo = FALSE
				break

		if(show_tattoo)
			tattoo_text_output += span_notice("На [ru_ego()] [BP.ru_name_v] набита татуировка: \"[BP.tattoo_text]\".\n")

	return tattoo_text_output
