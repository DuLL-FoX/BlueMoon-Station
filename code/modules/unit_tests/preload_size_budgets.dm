// BLUEMOON: regression guards against bloating the resources we push to every connecting client.
//
// Why these exist: BYOND's browse() queue is single-threaded per client. Anything we push via
// Export("##action=load_rsc", file) or browse_rsc() sits in that queue ahead of the critical UI
// HTML (statbrowser, TGUI windows). If the pre-UI payload grows past a few MB on a slow link,
// the client appears frozen on "Downloading resources" while statbrowser never loads —
// users perceive this as a disconnect and either reconnect or kill BYOND.
//
// See /client/proc/send_resources in client_procs.dm.

/datum/unit_test/vox_preload_size_budget/Run()
#ifdef AI_VOX
	// Measured 2026-07-31 after re-encoding the "Alliance" set from 44.1 kHz PCM
	// .wav to 24 kHz Ogg Vorbis: 17.7 MB across 1933 files, down from 60.2 MB.
	// Headroom is deliberately small so a new full voice set or another PCM import
	// fires the guard instead of quietly adding tens of megabytes to every login.
	var/budget_mb = 24
	var/budget_bytes = budget_mb * 1024 * 1024
	var/total_bytes = 0
	var/total_count = 0
	for(var/vox_type in GLOB.vox_types)
		var/list/word_to_file = GLOB.vox_types[vox_type]
		for(var/word in word_to_file)
			var/vox_file = word_to_file[word]
			// NOT length(file2text(...)): that stops at the first NUL byte, which every
			// OGG and WAV has within its first few bytes, so it measured the whole
			// catalog as a handful of bytes and the guard never fired. length() on a
			// file datum is the real size and reads nothing into memory.
			total_bytes += length(file("[vox_file]"))
			total_count++
	// Without this the test passes vacuously whenever the measurement breaks again.
	if(total_count)
		TEST_ASSERT(total_bytes > 0, "VOX preload measured 0 bytes across [total_count] files - the size guard is not measuring anything.")
	if(total_bytes > budget_bytes)
		var/total_mb_rounded = round(total_bytes / 1048576, 0.1)
		TEST_FAIL("VOX preload weighs [total_bytes] bytes (~[total_mb_rounded] MB across [total_count] files) — over the [budget_mb] MB budget. This is shipped to every connecting client by /client/proc/send_resources via Export(\"##action=load_rsc\"); bloating it clogs the browse() queue and stalls logins on \"Downloading resources\". Either trim the VOX catalog or comment out the AI_VOX define in code/__DEFINES/mobs.dm if VOX is no longer used.")
#endif
