// Smooth HUD updates, but low priority
PROCESSING_SUBSYSTEM_DEF(huds)
	name = "HUD updates"
	flags = SS_NO_INIT
	wait = 0.5
	priority = FIRE_PRIORITY_HUDS
	stat_tag = "HUDS"
