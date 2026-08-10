PROCESSING_SUBSYSTEM_DEF(wet_floors)
	name = "Wet floors"
	flags = SS_NO_INIT
	priority = FIRE_PRIORITY_WET_FLOORS
	wait = 10
	stat_tag = "WFP" //Used for logging
	var/temperature_coeff = 2
	var/time_ratio = 1.5 SECONDS
