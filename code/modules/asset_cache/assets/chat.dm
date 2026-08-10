/datum/asset/spritesheet_batched/chat
	name = "chat"

/datum/asset/spritesheet_batched/chat/create_spritesheets()
	insert_all_icons("emoji", 'icons/emoji.dmi')
	insert_all_icons("emoji", 'icons/emoji_32.dmi')
	// pre-loading all lanugage icons also helps to avoid meta
	insert_all_icons("language", 'icons/misc/language.dmi')
	// catch languages which are pulling icons from another file
	for(var/path in typesof(/datum/language))
		var/datum/language/L = path
		var/icon = initial(L.icon)
		if (icon && icon != 'icons/misc/language.dmi')
			var/icon_state = initial(L.icon_state)
			insert_icon("language-[icon_state]", uni_icon(icon, icon_state, SOUTH))
