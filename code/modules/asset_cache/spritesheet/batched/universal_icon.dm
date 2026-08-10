/// A serializable icon description consumed by rust-g IconForge.
/// Unlike /icon, constructing this datum does not decode or compose image data.
/datum/universal_icon
	var/icon/icon_file
	var/icon_state
	var/dir
	var/frame
	var/datum/icon_transformer/transform

/datum/universal_icon/New(icon/icon_file, icon_state = "", dir = null, frame = null, datum/icon_transformer/transform = null, color = null)
	src.icon_file = icon_file
	src.icon_state = icon_state
	src.dir = dir
	src.frame = frame
	if(!isnull(transform))
		src.transform = transform
	else if(!isnull(color) && uppertext(color) != "#FFFFFF")
		src.transform = new
		src.transform.blend_color(color, ICON_MULTIPLY)

/datum/universal_icon/proc/copy()
	var/datum/universal_icon/copied = new(icon_file, icon_state, dir, frame)
	if(transform)
		copied.transform = transform.copy()
	return copied

/datum/universal_icon/proc/blend_color(color, blend_mode)
	if(!transform)
		transform = new
	transform.blend_color(color, blend_mode)
	return src

/datum/universal_icon/proc/blend_icon(datum/universal_icon/icon_object, blend_mode, x = 1, y = 1)
	if(!transform)
		transform = new
	transform.blend_icon(icon_object, blend_mode, x, y)
	return src

/datum/universal_icon/proc/scale(width, height)
	if(!transform)
		transform = new
	transform.scale(width, height)
	return src

/datum/universal_icon/proc/crop(x1, y1, x2, y2)
	if(!transform)
		transform = new
	transform.crop(x1, y1, x2, y2)
	return src

/datum/universal_icon/proc/flip(direction)
	if(!transform)
		transform = new
	transform.flip(direction)
	return src

/datum/universal_icon/proc/rotate(angle)
	if(!transform)
		transform = new
	transform.rotate(angle)
	return src

/datum/universal_icon/proc/shift(direction, offset, wrap = FALSE)
	if(!transform)
		transform = new
	transform.shift(direction, offset, wrap)
	return src

/datum/universal_icon/proc/swap_color(source_color, destination_color)
	if(!transform)
		transform = new
	transform.swap_color(source_color, destination_color)
	return src

/datum/universal_icon/proc/draw_box(color, x1, y1, x2 = x1, y2 = y1)
	if(!transform)
		transform = new
	transform.draw_box(color, x1, y1, x2, y2)
	return src

/datum/universal_icon/proc/map_colors_rgba(rr, rg, rb, ra, gr, gg, gb, ga, br, bg, bb, ba, ar, ag, ab, aa, r0 = 0, g0 = 0, b0 = 0, a0 = 0)
	if(!transform)
		transform = new
	transform.map_colors(rr, rg, rb, ra, gr, gg, gb, ga, br, bg, bb, ba, ar, ag, ab, aa, r0, g0, b0, a0)
	return src

/datum/universal_icon/proc/change_opacity(amount)
	return blend_color("#ffffff[num2hex(clamp(amount, 0, 1) * 255, 2)]", ICON_MULTIPLY)

/datum/universal_icon/proc/to_list()
	return list(
		"icon_file" = "[icon_file]",
		"icon_state" = icon_state,
		"dir" = dir,
		"frame" = frame,
		"transform" = transform ? transform.to_list() : list(),
	)

/datum/universal_icon/proc/to_json()
	return json_encode(to_list())

/datum/universal_icon/proc/to_icon()
	var/icon/rendered = icon(icon_file, icon_state, dir = dir, frame = frame)
	if(transform)
		transform.apply(rendered)
	return rendered

/datum/icon_transformer
	var/list/transforms = list()

/datum/icon_transformer/proc/copy()
	var/datum/icon_transformer/copied = new
	for(var/list/original as anything in transforms)
		var/list/transform_copy = original.Copy()
		if(original["type"] == RUSTG_ICONFORGE_BLEND_ICON)
			var/datum/universal_icon/blended = original["icon"]
			transform_copy["icon"] = blended?.copy()
		copied.transforms += list(transform_copy)
	return copied

/datum/icon_transformer/proc/blend_color(color, blend_mode)
	transforms += list(list("type" = RUSTG_ICONFORGE_BLEND_COLOR, "color" = color, "blend_mode" = blend_mode))

/datum/icon_transformer/proc/blend_icon(datum/universal_icon/icon_object, blend_mode, x = 1, y = 1)
	if(!istype(icon_object))
		CRASH("Invalid universal icon supplied to blend_icon(): [icon_object]")
	transforms += list(list("type" = RUSTG_ICONFORGE_BLEND_ICON, "icon" = icon_object, "blend_mode" = blend_mode, "x" = x, "y" = y))

/datum/icon_transformer/proc/scale(width, height)
	transforms += list(list("type" = RUSTG_ICONFORGE_SCALE, "width" = width, "height" = height))

/datum/icon_transformer/proc/crop(x1, y1, x2, y2)
	transforms += list(list("type" = RUSTG_ICONFORGE_CROP, "x1" = x1, "y1" = y1, "x2" = x2, "y2" = y2))

/datum/icon_transformer/proc/flip(direction)
	transforms += list(list("type" = RUSTG_ICONFORGE_FLIP, "dir" = direction))

/datum/icon_transformer/proc/rotate(angle)
	transforms += list(list("type" = RUSTG_ICONFORGE_TURN, "angle" = angle))

/datum/icon_transformer/proc/shift(direction, offset, wrap = FALSE)
	transforms += list(list("type" = RUSTG_ICONFORGE_SHIFT, "dir" = direction, "offset" = offset, "wrap" = wrap))

/datum/icon_transformer/proc/swap_color(source_color, destination_color)
	transforms += list(list("type" = RUSTG_ICONFORGE_SWAP_COLOR, "src_color" = source_color, "dst_color" = destination_color))

/datum/icon_transformer/proc/draw_box(color, x1, y1, x2 = x1, y2 = y1)
	transforms += list(list("type" = RUSTG_ICONFORGE_DRAW_BOX, "color" = color, "x1" = x1, "y1" = y1, "x2" = x2, "y2" = y2))

/datum/icon_transformer/proc/map_colors(rr, rg, rb, ra, gr, gg, gb, ga, br, bg, bb, ba, ar, ag, ab, aa, r0 = 0, g0 = 0, b0 = 0, a0 = 0)
	transforms += list(list(
		"type" = RUSTG_ICONFORGE_MAP_COLORS,
		"rr" = rr, "rg" = rg, "rb" = rb, "ra" = ra,
		"gr" = gr, "gg" = gg, "gb" = gb, "ga" = ga,
		"br" = br, "bg" = bg, "bb" = bb, "ba" = ba,
		"ar" = ar, "ag" = ag, "ab" = ab, "aa" = aa,
		"r0" = r0, "g0" = g0, "b0" = b0, "a0" = a0,
	))

/datum/icon_transformer/proc/to_list()
	var/list/serialized = list()
	for(var/list/original as anything in transforms)
		var/list/transform_copy = original.Copy()
		if(original["type"] == RUSTG_ICONFORGE_BLEND_ICON)
			var/datum/universal_icon/blended = original["icon"]
			transform_copy["icon"] = blended.to_list()
		serialized += list(transform_copy)
	return serialized

/datum/icon_transformer/proc/apply(icon/target)
	for(var/list/icon_transform as anything in transforms)
		switch(icon_transform["type"])
			if(RUSTG_ICONFORGE_BLEND_COLOR)
				target.Blend(icon_transform["color"], icon_transform["blend_mode"])
			if(RUSTG_ICONFORGE_BLEND_ICON)
				var/datum/universal_icon/blended = icon_transform["icon"]
				target.Blend(blended.to_icon(), icon_transform["blend_mode"], icon_transform["x"], icon_transform["y"])
			if(RUSTG_ICONFORGE_SCALE)
				target.Scale(icon_transform["width"], icon_transform["height"])
			if(RUSTG_ICONFORGE_CROP)
				target.Crop(icon_transform["x1"], icon_transform["y1"], icon_transform["x2"], icon_transform["y2"])
			if(RUSTG_ICONFORGE_FLIP)
				target.Flip(icon_transform["dir"])
			if(RUSTG_ICONFORGE_TURN)
				target.Turn(icon_transform["angle"])
			if(RUSTG_ICONFORGE_SHIFT)
				target.Shift(icon_transform["dir"], icon_transform["offset"], icon_transform["wrap"])
			if(RUSTG_ICONFORGE_SWAP_COLOR)
				target.SwapColor(icon_transform["src_color"], icon_transform["dst_color"])
			if(RUSTG_ICONFORGE_DRAW_BOX)
				target.DrawBox(icon_transform["color"], icon_transform["x1"], icon_transform["y1"], icon_transform["x2"], icon_transform["y2"])
			if(RUSTG_ICONFORGE_MAP_COLORS)
				target.MapColors(
					icon_transform["rr"], icon_transform["rg"], icon_transform["rb"], icon_transform["ra"],
					icon_transform["gr"], icon_transform["gg"], icon_transform["gb"], icon_transform["ga"],
					icon_transform["br"], icon_transform["bg"], icon_transform["bb"], icon_transform["ba"],
					icon_transform["ar"], icon_transform["ag"], icon_transform["ab"], icon_transform["aa"],
					icon_transform["r0"], icon_transform["g0"], icon_transform["b0"], icon_transform["a0"],
				)
	return target
