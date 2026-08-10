/// Constructs an iconforge-compatible icon description without realizing a BYOND /icon.
/// Parameters mirror icon(): icon file, state, dir, frame, transformer, color.
#define uni_icon(I, icon_state, rest...) new /datum/universal_icon(I, icon_state, ##rest)
