// Representative icons for each research design
/datum/asset/spritesheet_batched/research_designs
	name = "design"

/datum/asset/spritesheet_batched/research_designs/create_spritesheets()
	var/list/icon_states_cache = list()
	for (var/path in subtypesof(/datum/design))
		var/datum/design/D = path

		var/icon_file
		var/icon_state
		var/datum/universal_icon/icon_entry

		if(initial(D.research_icon) && initial(D.research_icon_state)) //If the design has an icon replacement skip the rest
			icon_file = initial(D.research_icon)
			icon_state = initial(D.research_icon_state)
			var/list/available_states = icon_states_cache[icon_file]
			if(isnull(available_states))
				available_states = icon_states(icon_file) || list()
				icon_states_cache[icon_file] = available_states
			if(!(icon_state in available_states))
				warning("design [D] with icon '[icon_file]' missing state '[icon_state]'")
				continue
			icon_entry = uni_icon(icon_file, icon_state, SOUTH)

		else
			// construct the icon and slap it into the resource cache
			var/atom/item = initial(D.build_path)
			if (!ispath(item, /atom))
				// biogenerator outputs to beakers by default
				if (initial(D.build_type) & BIOGENERATOR)
					item = /obj/item/reagent_containers/glass/beaker/large
				else
					continue  // shouldn't happen, but just in case

			// circuit boards become their resulting machines or computers
			if (ispath(item, /obj/item/circuitboard))
				var/obj/item/circuitboard/C = item
				var/machine = initial(C.build_path)
				if (machine)
					item = machine

			// Check for GAGS support where necessary
			// var/greyscale_config = initial(item.greyscale_config)
			// var/greyscale_colors = initial(item.greyscale_colors)
			// if (greyscale_config && greyscale_colors)
			// 	icon_file = SSgreyscale.GetColoredIconByType(greyscale_config, greyscale_colors)
			// else
			icon_file = initial(item.icon)

			icon_state = initial(item.icon_state)
			var/list/available_states = icon_states_cache[icon_file]
			if(isnull(available_states))
				available_states = icon_states(icon_file) || list()
				icon_states_cache[icon_file] = available_states
			if(!(icon_state in available_states))
				warning("design [D] with icon '[icon_file]' missing state '[icon_state]'")
				continue
			icon_entry = uni_icon(icon_file, icon_state, SOUTH)

			// computers (and snowflakes) get their screen and keyboard sprites
			if (ispath(item, /obj/machinery/computer) || ispath(item, /obj/machinery/power/solar_control))
				var/obj/machinery/computer/C = item
				var/screen = initial(C.icon_screen)
				var/keyboard = initial(C.icon_keyboard)
				if (screen && (screen in available_states))
					icon_entry.blend_icon(uni_icon(icon_file, screen, SOUTH), ICON_OVERLAY)
				if (keyboard && (keyboard in available_states))
					icon_entry.blend_icon(uni_icon(icon_file, keyboard, SOUTH), ICON_OVERLAY)

		insert_icon(initial(D.id), icon_entry)
