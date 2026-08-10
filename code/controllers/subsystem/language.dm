SUBSYSTEM_DEF(language)
	name = "Language"
	init_order = INIT_ORDER_LANGUAGE
	flags = SS_NO_FIRE
	var/list/languages_by_name = list() //Sandstorm CHANGE - language bullshit

/datum/controller/subsystem/language/Initialize()
	for(var/L in subtypesof(/datum/language))
		var/datum/language/language = L
		if(!initial(language.key))
			continue

		GLOB.all_languages += language

		var/datum/language/instance = new language

		GLOB.language_datum_instances[language] = instance
		//Sandstorm change
		languages_by_name[initial(language.name)] = instance
		//

	return SS_INIT_SUCCESS
