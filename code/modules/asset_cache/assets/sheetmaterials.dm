/datum/asset/spritesheet_batched/sheetmaterials
	name = "sheetmaterials"

/datum/asset/spritesheet_batched/sheetmaterials/create_spritesheets()
	// Insert polycrystal from telescience first so it won't be duplicated when stacking from stack_objects.dmi
	insert_icon("polycrystal", uni_icon('icons/obj/telescience.dmi', "polycrystal", SOUTH))
	for (var/icon_state_name in icon_states('icons/obj/stack_objects.dmi'))
		if (icon_state_name == "polycrystal")
			continue
		insert_icon(icon_state_name, uni_icon('icons/obj/stack_objects.dmi', icon_state_name, SOUTH))
