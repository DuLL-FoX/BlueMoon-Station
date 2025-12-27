// Хирургическая операция по удалению татуировок
// Единственный способ убрать перманентные татуировки

/datum/surgery/tattoo_removal
	name = "Удаление татуировки"
	desc = "Хирургическая процедура по удалению татуировок с кожи."
	steps = list(
		/datum/surgery_step/incise,
		/datum/surgery_step/retract_skin,
		/datum/surgery_step/remove_tattoo,
		/datum/surgery_step/close
	)
	possible_locs = list(
		BODY_ZONE_HEAD,
		BODY_ZONE_CHEST,
		BODY_ZONE_L_ARM,
		BODY_ZONE_R_ARM,
		BODY_ZONE_L_LEG,
		BODY_ZONE_R_LEG
	)
	requires_bodypart_type = BODYPART_ORGANIC
	is_healing = FALSE
	icon_state = "surgery_any"
	radial_priority = SURGERY_RADIAL_PRIORITY_OTHER_SECOND

/datum/surgery/tattoo_removal/can_start(mob/user, mob/living/carbon/target, obj/item/tool)
	. = ..()
	if(!.)
		return FALSE

	// Проверяем, есть ли татуировки на выбранной части тела
	var/obj/item/bodypart/BP = target.get_bodypart(user.zone_selected)
	if(!BP)
		return FALSE

	if(!BP.tattoo_text || BP.tattoo_text == "")
		return FALSE

	return TRUE

// Шаг удаления татуировки
/datum/surgery_step/remove_tattoo
	name = "Удалить татуировку"
	implements = list(
		TOOL_SCALPEL = 100,
		/obj/item/kitchen/knife = 65,
		TOOL_WIRECUTTER = 40
	)
	time = 80

/datum/surgery_step/remove_tattoo/preop(mob/user, mob/living/carbon/target, target_zone, obj/item/tool, datum/surgery/surgery)
	var/obj/item/bodypart/BP = target.get_bodypart(target_zone)
	if(!BP || !BP.tattoo_text)
		to_chat(user, span_warning("На этой части тела нет татуировок!"))
		return -1

	display_results(
		user,
		target,
		span_notice("Вы начинаете аккуратно срезать слои кожи с татуировкой на [BP.ru_name_v] [target]..."),
		span_notice("[user] начинает аккуратно срезать кожу на [BP.ru_name_v] [target]."),
		span_notice("[user] делает надрезы на [BP.ru_name_v] [target].")
	)

/datum/surgery_step/remove_tattoo/success(mob/user, mob/living/carbon/target, target_zone, obj/item/tool, datum/surgery/surgery)
	var/obj/item/bodypart/BP = target.get_bodypart(target_zone)
	if(!BP)
		return FALSE

	// Удаляем все татуировки с этой части тела
	BP.tattoo_text = ""

	display_results(
		user,
		target,
		span_notice("Вы успешно удалили татуировку с [BP.ru_name_v] [target]."),
		span_notice("[user] успешно удаляет татуировку с [BP.ru_name_v] [target]."),
		span_notice("[user] заканчивает работу на [BP.ru_name_v] [target].")
	)

	// Небольшой урон от процедуры
	target.apply_damage(5, BRUTE, BP)

	return TRUE

/datum/surgery_step/remove_tattoo/failure(mob/user, mob/living/carbon/target, target_zone, obj/item/tool, datum/surgery/surgery)
	. = ..()
	var/obj/item/bodypart/BP = target.get_bodypart(target_zone)
	if(!BP)
		return

	display_results(
		user,
		target,
		span_warning("Вы случайно порезали кожу слишком глубоко!"),
		span_warning("[user] случайно режет слишком глубоко!"),
		span_warning("[user] делает резкое движение скальпелем!")
	)

	// Урон при неудаче
	target.apply_damage(15, BRUTE, BP)

// Операция по частичному удалению татуировки (выбор конкретной)
/datum/surgery/tattoo_removal_selective
	name = "Выборочное удаление татуировки"
	desc = "Хирургическая процедура по удалению конкретной татуировки с кожи, оставляя остальные."
	steps = list(
		/datum/surgery_step/incise,
		/datum/surgery_step/retract_skin,
		/datum/surgery_step/remove_tattoo_selective,
		/datum/surgery_step/close
	)
	possible_locs = list(
		BODY_ZONE_HEAD,
		BODY_ZONE_CHEST,
		BODY_ZONE_L_ARM,
		BODY_ZONE_R_ARM,
		BODY_ZONE_L_LEG,
		BODY_ZONE_R_LEG
	)
	requires_bodypart_type = BODYPART_ORGANIC
	is_healing = FALSE
	icon_state = "surgery_any"
	radial_priority = SURGERY_RADIAL_PRIORITY_OTHER_SECOND + 1

/datum/surgery/tattoo_removal_selective/can_start(mob/user, mob/living/carbon/target, obj/item/tool)
	. = ..()
	if(!.)
		return FALSE

	var/obj/item/bodypart/BP = target.get_bodypart(user.zone_selected)
	if(!BP)
		return FALSE

	// Проверяем, есть ли несколько татуировок
	if(!BP.tattoo_text || BP.tattoo_text == "")
		return FALSE

	// Показываем эту операцию только если есть несколько татуировок
	if(!findtext(BP.tattoo_text, ";"))
		return FALSE

	return TRUE

// Шаг выборочного удаления татуировки
/datum/surgery_step/remove_tattoo_selective
	name = "Выборочно удалить татуировку"
	implements = list(
		TOOL_SCALPEL = 100,
		/obj/item/kitchen/knife = 65
	)
	time = 60

/datum/surgery_step/remove_tattoo_selective/preop(mob/user, mob/living/carbon/target, target_zone, obj/item/tool, datum/surgery/surgery)
	var/obj/item/bodypart/BP = target.get_bodypart(target_zone)
	if(!BP || !BP.tattoo_text)
		to_chat(user, span_warning("На этой части тела нет татуировок!"))
		return -1

	// Получаем список татуировок
	var/list/tattoos = splittext(BP.tattoo_text, "; ")
	if(!length(tattoos) || length(tattoos) < 2)
		to_chat(user, span_warning("Недостаточно татуировок для выборочного удаления!"))
		return -1

	// Даём выбрать какую удалить
	var/choice = input(user, "Выберите татуировку для удаления:", "Удаление татуировки") as null|anything in tattoos
	if(!choice)
		return -1

	surgery.tattoo_to_remove = choice

	display_results(
		user,
		target,
		span_notice("Вы начинаете аккуратно удалять выбранную татуировку с [BP.ru_name_v] [target]..."),
		span_notice("[user] начинает аккуратно работать над кожей [BP.ru_name_v] [target]."),
		span_notice("[user] делает надрезы на [BP.ru_name_v] [target].")
	)

/datum/surgery_step/remove_tattoo_selective/success(mob/user, mob/living/carbon/target, target_zone, obj/item/tool, datum/surgery/surgery)
	var/obj/item/bodypart/BP = target.get_bodypart(target_zone)
	if(!BP)
		return FALSE

	// Удаляем выбранную татуировку
	var/list/tattoos = splittext(BP.tattoo_text, "; ")
	tattoos -= surgery.tattoo_to_remove
	BP.tattoo_text = jointext(tattoos, "; ")

	display_results(
		user,
		target,
		span_notice("Вы успешно удалили выбранную татуировку с [BP.ru_name_v] [target]."),
		span_notice("[user] успешно удаляет татуировку с [BP.ru_name_v] [target]."),
		span_notice("[user] заканчивает работу на [BP.ru_name_v] [target].")
	)

	target.apply_damage(3, BRUTE, BP)
	return TRUE

// Расширение датума хирургии для хранения выбранной татуировки
/datum/surgery
	/// Татуировка, которую нужно удалить (для выборочного удаления)
	var/tattoo_to_remove = ""
