/datum/config_entry/keyed_list/external_rsc_urls
	key_mode = KEY_MODE_TEXT
	value_mode = VALUE_MODE_FLAG

/**
 * Выдавать ли клиентам внешние адреса .rsc.
 *
 * Адреса версионного архива зашиты в сборку деплоем (DEPLOYMENT_RSC_URLS), поэтому
 * без рантайм-выключателя пропавший с раздачи архив лечился бы перекомпиляцией.
 * Значение уезжает в GLOB.external_rsc_delivery_enabled, который и читает
 * send_resources() на каждом входе - это же значение переключает админский верб.
 */
/datum/config_entry/flag/external_rsc_delivery
	default = TRUE
	postload_required = TRUE

/datum/config_entry/flag/external_rsc_delivery/OnPostload()
	GLOB.external_rsc_delivery_enabled = config_entry_value

/**
 * Период активной пробы внешней раздачи в секундах. 0 - SScdn_probe не работает.
 *
 * Включена по умолчанию: смысл пробы в том, чтобы про упавшую раздачу узнали раньше
 * игроков, а энтри, которую надо сначала дописать в конфиг, на проде так и осталась бы
 * дефолтной. Ложных срабатываний на локальных сборках это не даёт - SScdn_probe
 * проверяет только те цели, которые в сборке реально есть, и на дев-машине их ноль.
 */
/datum/config_entry/number/cdn_probe_interval
	default = 300
	min_val = 0

/datum/config_entry/flag/asset_simple_preload

/datum/config_entry/string/asset_transport
/datum/config_entry/string/asset_transport/ValidateAndSet(str_val)
	return (lowertext(str_val) in list("simple", "webroot")) && ..(lowertext(str_val))

/datum/config_entry/string/asset_cdn_webroot
	protection = CONFIG_ENTRY_LOCKED

/datum/config_entry/string/asset_cdn_webroot/ValidateAndSet(str_var)
	if (!str_var || trim(str_var) == "")
		return FALSE
	if (str_var && str_var[length(str_var)] != "/")
		str_var += "/"
	return ..(str_var)

/datum/config_entry/string/asset_cdn_url
	protection = CONFIG_ENTRY_LOCKED
	default = null

/datum/config_entry/string/asset_cdn_url/ValidateAndSet(str_var)
	if (!str_var || trim(str_var) == "")
		return FALSE
	if (str_var && str_var[length(str_var)] != "/")
		str_var += "/"
	return ..(str_var)
