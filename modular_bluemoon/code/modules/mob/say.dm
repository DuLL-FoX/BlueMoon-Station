/**
 * Шёпот с текстом в параметре.
 *
 * Параметр здесь не для удобства: получив его, клиент открывает диалог сам и
 * не ждёт ответа сервера, а несколько таких диалогов спокойно живут
 * одновременно. Пара к Speak и Emote для нативного режима ввода.
 */
/mob/verb/whisper_text(message as text)
	set name = "Whisper-Text"
	set hidden = TRUE
	if(!length(message))
		return
	if(GLOB.say_disabled)
		to_chat(usr, span_danger("Speech is currently admin-disabled."))
		return
	clear_typing_indicator()
	client?.last_activity = world.time
	QUEUE_OR_CALL_VERB_FOR(VERB_CALLBACK(src, TYPE_PROC_REF(/mob, whisper), message), SSspeech_controller)

/mob/verb/whisper_typing_indicator()
	set name = "Whisper (Indicator)"
	set hidden = TRUE
	set category = "Say"
	if(GLOB.say_disabled)	//This is here to try to identify lag problems
		to_chat(usr, "<span class='danger'>Speech is currently admin-disabled.</span>")
		return
	display_typing_indicator(isSay = TRUE)
	
	var/message = ""
	if(client?.prefs.say_input_mode == SAY_INPUT_MODE_MODAL)
		message = tgui_input_text(src, "", "Whisper (Indicator)", null, MAX_MESSAGE_LEN, encode = TRUE)
	else
		message = stripped_input(src, "", "Whisper (Indicator)")

	clear_typing_indicator()
	if(!length(message))
		return
	QUEUE_OR_CALL_VERB_FOR(VERB_CALLBACK(src, TYPE_PROC_REF(/mob, whisper), message), SSspeech_controller)
