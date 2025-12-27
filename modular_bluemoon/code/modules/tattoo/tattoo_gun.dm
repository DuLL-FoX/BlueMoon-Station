// Tattoo Gun - тату-машинка для нанесения перманентных татуировок
// В отличие от надписей ручкой, татуировки не смываются водой/мылом
// Для удаления требуется хирургическая операция

/obj/item/tattoo_gun
	name = "tattoo gun"
	desc = "Профессиональная тату-машинка для нанесения перманентных татуировок. Татуировки можно удалить только хирургическим путём."
	// TODO: Заменить на собственные спрайты когда они будут готовы
	icon = 'icons/obj/device.dmi'
	icon_state = "turret_control" // Временный спрайт
	lefthand_file = 'icons/mob/inhands/equipment/tools_lefthand.dmi'
	righthand_file = 'icons/mob/inhands/equipment/tools_righthand.dmi'
	w_class = WEIGHT_CLASS_SMALL
	force = 0
	throwforce = 0
	item_flags = NOBLUDGEON

	/// Цвет чернил для татуировки
	var/ink_color = "#000000"
	/// Название стиля чернил
	var/ink_style = "черные"

/obj/item/tattoo_gun/Initialize(mapload)
	. = ..()
	update_appearance()

/obj/item/tattoo_gun/examine(mob/user)
	. = ..()
	. += span_notice("Текущий цвет чернил: <span style='color:[ink_color]'>[ink_style]</span>.")
	. += span_notice("Используйте ПКМ на тату-машинке, чтобы сменить цвет чернил.")
	. += span_warning("Татуировки можно удалить только хирургическим путём!")

/obj/item/tattoo_gun/attack_self(mob/user)
	// Открыть меню выбора цвета чернил
	var/list/ink_choices = list(
		"Черные" = "#000000",
		"Красные" = "#AA0000",
		"Синие" = "#0000AA",
		"Зелёные" = "#00AA00",
		"Фиолетовые" = "#AA00AA",
		"Золотые" = "#FFD700",
		"Белые" = "#FFFFFF"
	)

	var/choice = input(user, "Выберите цвет чернил для татуировки:", "Цвет чернил") as null|anything in ink_choices
	if(!choice || !user.is_holding(src))
		return

	ink_color = ink_choices[choice]
	ink_style = lowertext(choice)
	to_chat(user, span_notice("Вы заправили [src] [ink_style] чернилами."))

/obj/item/tattoo_gun/attack(mob/living/M, mob/living/user)
	if(!istype(M) || !iscarbon(M))
		return ..()

	if(user.a_intent == INTENT_HARM)
		return ..()

	var/mob/living/carbon/human/target = M
	if(!ishuman(target))
		to_chat(user, span_warning("Вы не можете набить татуировку этому существу!"))
		return

	// Выбор части тела через радиальное меню
	var/selected_zone = select_body_zone_radial(user, target)
	if(!selected_zone)
		return

	// Проверка на одежду
	var/target_body_part = zone2body_parts_covered_complicated(selected_zone)
	if(!target_body_part)
		to_chat(user, span_warning("Вы должны выбрать часть тела!"))
		return

	var/list/items_on_target = target.get_equipped_items()
	for(var/obj/item/worn_clothes in items_on_target)
		if(worn_clothes.body_parts_covered & target_body_part)
			to_chat(user, span_warning("Вам мешает одежда [target]!"))
			return

	// Получаем часть тела
	var/actual_zone = selected_zone
	if(selected_zone == BODY_ZONE_PRECISE_GROIN)
		actual_zone = BODY_ZONE_CHEST

	var/obj/item/bodypart/BP = target.get_bodypart(actual_zone)
	if(!BP)
		to_chat(user, span_warning("У [target] отсутствует эта часть тела!"))
		return

	// Ввод текста татуировки
	var/tattoo_text = tgui_input_text(user, "Введите текст или описание татуировки (макс. 150 символов):", "Татуировка на [BP.ru_name_v]", max_length = 150)
	if(!tattoo_text)
		return

	if(!user.canUseTopic(src, BE_CLOSE))
		return

	// Начинаем процесс нанесения татуировки
	if(user != target)
		user.visible_message(span_notice("[user] начинает набивать татуировку на [BP.ru_name_v] [target]."), \
			span_notice("Вы начинаете набивать татуировку на [BP.ru_name_v] [target]."))
	else
		to_chat(user, span_notice("Вы начинаете набивать себе татуировку на [BP.ru_name_v]."))

	// Нанесение татуировки занимает 8 секунд
	if(!do_mob(user, target, 8 SECONDS))
		to_chat(user, span_warning("Процесс нанесения татуировки прерван!"))
		return

	// Проверяем лимит символов на части тела
	var/new_tattoo = "<span style='color:[ink_color]'>[html_encode(tattoo_text)]</span>"
	if((length(BP.tattoo_text) + length(new_tattoo)) > 500)
		to_chat(user, span_warning("На [BP.ru_name_v] [target] недостаточно места для ещё одной татуировки!"))
		return

	// Добавляем татуировку
	if(BP.tattoo_text)
		BP.tattoo_text += "; " + new_tattoo
	else
		BP.tattoo_text = new_tattoo

	// Сообщения о успехе
	if(user != target)
		user.visible_message(span_notice("[user] набил[user.ru_a()] татуировку на [BP.ru_name_v] [target]."), \
			span_notice("Вы набили татуировку на [BP.ru_name_v] [target]."))
		to_chat(target, span_notice("[user] набил[user.ru_a()] вам татуировку на [BP.ru_name_v]!"))
	else
		to_chat(user, span_notice("Вы набили себе татуировку на [BP.ru_name_v]."))

	// Небольшой урон от иглы
	target.apply_damage(1, BRUTE, BP)

/// Выбор части тела через радиальное меню
/obj/item/tattoo_gun/proc/select_body_zone_radial(mob/user, mob/living/carbon/human/target)
	var/list/body_zones = list()

	// Создаём список частей тела с иконками
	var/static/list/zone_icons
	if(!zone_icons)
		zone_icons = list()
		zone_icons[BODY_ZONE_HEAD] = image(icon = 'icons/mob/screen_gen.dmi', icon_state = "zone_sel_head")
		zone_icons[BODY_ZONE_CHEST] = image(icon = 'icons/mob/screen_gen.dmi', icon_state = "zone_sel_chest")
		zone_icons[BODY_ZONE_L_ARM] = image(icon = 'icons/mob/screen_gen.dmi', icon_state = "zone_sel_l_arm")
		zone_icons[BODY_ZONE_R_ARM] = image(icon = 'icons/mob/screen_gen.dmi', icon_state = "zone_sel_r_arm")
		zone_icons[BODY_ZONE_L_LEG] = image(icon = 'icons/mob/screen_gen.dmi', icon_state = "zone_sel_l_leg")
		zone_icons[BODY_ZONE_R_LEG] = image(icon = 'icons/mob/screen_gen.dmi', icon_state = "zone_sel_r_leg")

	// Добавляем только те части тела, которые есть у цели
	if(target.get_bodypart(BODY_ZONE_HEAD))
		body_zones["Голова"] = zone_icons[BODY_ZONE_HEAD]
	if(target.get_bodypart(BODY_ZONE_CHEST))
		body_zones["Туловище"] = zone_icons[BODY_ZONE_CHEST]
	if(target.get_bodypart(BODY_ZONE_L_ARM))
		body_zones["Левая рука"] = zone_icons[BODY_ZONE_L_ARM]
	if(target.get_bodypart(BODY_ZONE_R_ARM))
		body_zones["Правая рука"] = zone_icons[BODY_ZONE_R_ARM]
	if(target.get_bodypart(BODY_ZONE_L_LEG))
		body_zones["Левая нога"] = zone_icons[BODY_ZONE_L_LEG]
	if(target.get_bodypart(BODY_ZONE_R_LEG))
		body_zones["Правая нога"] = zone_icons[BODY_ZONE_R_LEG]

	if(!length(body_zones))
		to_chat(user, span_warning("У [target] нет доступных частей тела для татуировки!"))
		return null

	var/choice = show_radial_menu(user, target, body_zones, require_near = TRUE, tooltips = TRUE)
	if(!choice)
		return null

	// Преобразуем выбор обратно в зону тела
	switch(choice)
		if("Голова")
			return BODY_ZONE_HEAD
		if("Туловище")
			return BODY_ZONE_CHEST
		if("Левая рука")
			return BODY_ZONE_L_ARM
		if("Правая рука")
			return BODY_ZONE_R_ARM
		if("Левая нога")
			return BODY_ZONE_L_LEG
		if("Правая нога")
			return BODY_ZONE_R_LEG

	return null
