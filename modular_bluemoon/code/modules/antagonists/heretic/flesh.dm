#define HERETIC_FLESH_STITCH_DAMAGE 15
#define HERETIC_FLESH_STITCH_HEALING 15
#define HERETIC_FLESH_STITCH_STEPS 2

/obj/effect/proc_holder/spell/pointed/heretic_flesh_stitch
	name = "Живой шов"
	desc = "Протяните сухожилие на 5 клеток: враг получает 15 ушибов и замедляется на 3 секунды. Свой слуга вместо этого восстанавливает по 15 ушибов и ожогов и подтягивается к вам на два шага за 1 биомассу. Стены и закрытые двери прерывают шов; пристёгнутого слугу можно вылечить, но нельзя сдвинуть."
	clothes_req = FALSE
	charge_max = 15 SECONDS
	range = 5
	invocation = "S'UT'RE"
	invocation_type = "whisper"
	action_icon = 'modular_bluemoon/icons/obj/heretic_actions.dmi'
	action_icon_state = "flesh_mend"
	action_background_icon_state = "bg_ecult"

/obj/effect/proc_holder/spell/pointed/heretic_flesh_stitch/proc/valid_user(mob/living/user)
	var/datum/antagonist/heretic/heretic = IS_HERETIC(user)
	return !QDELETED(src) && isliving(user) && heretic && !heretic.role_removed && heretic.selected_path == PATH_FLESH && heretic.owner?.current == user && user.stat == CONSCIOUS && !user.incapacitated() && heretic.get_knowledge(/datum/eldritch_knowledge/base_flesh) && heretic.get_knowledge(/datum/eldritch_knowledge/flesh_grasp)

/obj/effect/proc_holder/spell/pointed/heretic_flesh_stitch/can_cast(mob/user, skipcharge, silent)
	return ..() && valid_user(user)

/obj/effect/proc_holder/spell/pointed/heretic_flesh_stitch/can_target(atom/target, mob/user, silent)
	var/datum/antagonist/heretic/heretic = IS_HERETIC(user)
	if(!valid_user(user) || !isliving(target) || QDELETED(target) || target == user || !isturf(user.loc) || !isturf(target.loc))
		return FALSE
	var/mob/living/victim = target
	if(victim.stat == DEAD || user.z != victim.z || get_dist(user, victim) > range)
		return FALSE
	var/turf/previous
	for(var/turf/tile as anything in get_line(user, victim))
		if(!isopenturf(tile) || tile.is_blocked_turf(exclude_mobs = TRUE))
			return FALSE
		if(previous && previous.x != tile.x && previous.y != tile.y)
			var/turf/side_horizontal = locate(previous.x, tile.y, tile.z)
			var/turf/side_vertical = locate(tile.x, previous.y, tile.z)
			if(!isopenturf(side_horizontal) || !isopenturf(side_vertical) || side_horizontal.is_blocked_turf(exclude_mobs = TRUE) || side_vertical.is_blocked_turf(exclude_mobs = TRUE))
				return FALSE
		previous = tile
	var/datum/antagonist/heretic_monster/servant = IS_HERETIC_MONSTER(victim)
	if(servant?.master == heretic)
		var/datum/eldritch_knowledge/base_flesh/path = heretic.get_knowledge(/datum/eldritch_knowledge/base_flesh)
		var/needs_healing = victim.getBruteLoss() > 0 || victim.getFireLoss() > 0
		var/can_reposition = get_dist(user, victim) > 1 && !victim.anchored && !victim.buckled
		return path?.combat_resource > 0 && (needs_healing || can_reposition) && !victim.check_magic_resistance(chargecost = 0)
	return heretic_can_affect(user, victim, chargecost = 0)

/obj/effect/proc_holder/spell/pointed/heretic_flesh_stitch/cast(list/targets, mob/user)
	if(!length(targets) || !can_target(targets[1], user, TRUE))
		revert_cast(user)
		return
	var/mob/living/victim = targets[1]
	var/datum/antagonist/heretic/heretic = IS_HERETIC(user)
	var/datum/antagonist/heretic_monster/servant = IS_HERETIC_MONSTER(victim)
	if(servant?.master == heretic)
		var/datum/eldritch_knowledge/base_flesh/path = heretic.get_knowledge(/datum/eldritch_knowledge/base_flesh)
		if(!path?.spend_combat_resource())
			revert_cast(user)
			return
		victim.adjustBruteLoss(-HERETIC_FLESH_STITCH_HEALING)
		victim.adjustFireLoss(-HERETIC_FLESH_STITCH_HEALING)
		if(!victim.anchored && !victim.buckled)
			for(var/step_index in 1 to HERETIC_FLESH_STITCH_STEPS)
				if(get_dist(user, victim) <= 1 || !step_towards(victim, user))
					break
		new /obj/effect/temp_visual/heretic_oldpath/flesh/mend(get_turf(victim))
		to_chat(victim, span_notice("Живой шов затягивает ваши раны и тянет к хозяину."))
	else
		if(!heretic_can_affect(user, victim))
			return
		victim.adjustBruteLoss(HERETIC_FLESH_STITCH_DAMAGE)
		victim.apply_status_effect(/datum/status_effect/heretic_flesh_stitch)
		new /obj/effect/temp_visual/heretic_oldpath/flesh(get_turf(victim))
		to_chat(victim, span_warning("Сухожилие впивается в вас и стягивает движения!"))
	user.Beam(victim, icon_state = "drainbeam", time = 0.8 SECONDS)
	playsound(user, 'sound/effects/wounds/blood2.ogg', 60, TRUE)

/datum/status_effect/heretic_flesh_stitch
	id = "heretic_flesh_stitch"
	duration = 3 SECONDS
	tick_interval = -1
	status_type = STATUS_EFFECT_UNIQUE
	alert_type = null
	on_remove_on_mob_delete = TRUE

/datum/status_effect/heretic_flesh_stitch/on_apply()
	. = ..()
	if(!.)
		return FALSE
	owner.add_movespeed_modifier(/datum/movespeed_modifier/heretic_flesh_stitch)
	return TRUE

/datum/status_effect/heretic_flesh_stitch/on_remove()
	owner.remove_movespeed_modifier(/datum/movespeed_modifier/heretic_flesh_stitch)
	return ..()

/datum/movespeed_modifier/heretic_flesh_stitch
	multiplicative_slowdown = 1

#undef HERETIC_FLESH_STITCH_DAMAGE
#undef HERETIC_FLESH_STITCH_HEALING
#undef HERETIC_FLESH_STITCH_STEPS
