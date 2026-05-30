extends RefCounted
## Pure-rendering helper for MainMenu's weapon catalog dialog. Extracted from
## main_menu.gd (P1-14 god-object split) — this file owns ONLY the visual
## construction of weapon cards (stat bars, badges, ability callouts, upgrade
## buttons). It holds no menu state.
##
## The one piece of behaviour it can't own is the upgrade-button action,
## which needs the menu's multiplayer peer + Settings. So `populate` takes an
## `on_upgrade` Callable(weapon_id: String, stat: String, target_level: int)
## that the caller (main_menu) supplies — keeping this builder decoupled from
## networking / autoloads.
##
## Reference via `const ... = preload(...)` (not class_name — matches the
## weapon_registry.gd / player_visuals.gd convention so headless tests don't
## depend on the editor having populated the global class registry). All
## methods are static so there's nothing to instantiate.

const WEAPONS_DIR := "res://shared/data/weapons/"


## Wipe + rebuild every weapon card under `weapons_list`. `settings` may be
## null (offline) — upgrade levels just render as 0. `on_upgrade` is invoked
## when an upgrade button is pressed.
# type_label keyword (lowercase substring) → weapon-category icon PNG.
# Order matters: specific before generic. Falls through to the AR icon.
const _ICON_DIR := "res://assets/ui/generated/"
const _ICON_TABLE := [
	["sniper", "wicon_sniper"], ["anti-material", "wicon_sniper"], ["railgun", "wicon_sniper"],
	["shotgun", "wicon_shotgun"],
	["smg", "wicon_smg"], ["pdw", "wicon_smg"],
	["pistol", "wicon_pistol"], ["secondary", "wicon_pistol"], ["revolver", "wicon_pistol"],
	["beam", "wicon_energy"], ["laser", "wicon_energy"], ["arc", "wicon_energy"],
	["lightning", "wicon_energy"], ["plasma", "wicon_energy"], ["energy", "wicon_energy"],
	["bow", "wicon_explosive"], ["launcher", "wicon_explosive"], ["rocket", "wicon_explosive"],
	["explosive", "wicon_explosive"], ["knockback", "wicon_explosive"], ["throwable", "wicon_explosive"],
	["melee", "wicon_melee"], ["knife", "wicon_melee"], ["blade", "wicon_melee"], ["sword", "wicon_melee"],
]
static func _category_icon(type_label: String) -> String:
	var lbl := type_label.to_lower()
	for pair in _ICON_TABLE:
		if lbl.find(pair[0]) != -1:
			return _ICON_DIR + pair[1] + ".png"
	return _ICON_DIR + "wicon_ar.png"


static func populate(weapons_list: VBoxContainer, settings: Node, on_upgrade: Callable) -> void:
	for child in weapons_list.get_children():
		child.queue_free()
	var dir := DirAccess.open(WEAPONS_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var fname: String = dir.get_next()
		if fname == "":
			break
		# Web export rewrites .tres → .tres.remap (path indirection). Without
		# stripping the suffix the suffix check below rejects everything and
		# the dialog ends up empty on web. Matches weapon_registry.gd:42.
		if fname.ends_with(".tres.remap"):
			fname = fname.substr(0, fname.length() - 6)
		if dir.current_is_dir() or fname.begins_with("_") or not fname.ends_with(".tres"):
			continue
		var wpn: Resource = load(WEAPONS_DIR + fname)
		if wpn == null:
			continue
		weapons_list.add_child(_append_weapon_row(wpn, settings, on_upgrade))
	dir.list_dir_end()


static func _append_weapon_row(wpn: Resource, settings: Node, on_upgrade: Callable) -> PanelContainer:
	# ── Card container with cyan border + rounded corners ────────────────────
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(680, 0)
	card.add_theme_stylebox_override(&"panel", _weapon_card_style(wpn))

	var pad := MarginContainer.new()
	pad.add_theme_constant_override(&"margin_left", 18)
	pad.add_theme_constant_override(&"margin_right", 18)
	pad.add_theme_constant_override(&"margin_top", 14)
	pad.add_theme_constant_override(&"margin_bottom", 14)
	card.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 8)
	pad.add_child(col)

	# Header row: category icon + name + type + badges.
	var header := HBoxContainer.new()
	header.add_theme_constant_override(&"separation", 12)
	col.add_child(header)

	var icon_path: String = _category_icon(String(wpn.type_label))
	if icon_path != "" and ResourceLoader.exists(icon_path):
		var icon := TextureRect.new()
		icon.texture = load(icon_path)
		icon.custom_minimum_size = Vector2(34, 34)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		header.add_child(icon)

	var name_lbl := Label.new()
	name_lbl.text = wpn.display_name
	name_lbl.add_theme_font_size_override(&"font_size", 22)
	name_lbl.add_theme_color_override(&"font_color", Color(1, 0.88, 0.42))
	header.add_child(name_lbl)

	var type_lbl := Label.new()
	type_lbl.text = "·" + wpn.type_label
	type_lbl.add_theme_font_size_override(&"font_size", 14)
	type_lbl.add_theme_color_override(&"font_color", Color(0.55, 0.82, 1, 0.85))
	header.add_child(type_lbl)

	var header_spacer := Control.new()
	header_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(header_spacer)

	if wpn.instakill_headshot:
		header.add_child(_make_badge("☠ 头爆秒杀", Color(1, 0.4, 0.4)))
	if wpn.scary_close:
		header.add_child(_make_badge("⚠ 近战凶器", Color(1, 0.7, 0.3)))
	if wpn.free_starter:
		header.add_child(_make_badge("FREE", Color(0.5, 1, 0.6)))
	if wpn.admin_only:
		header.add_child(_make_badge("ADMIN", Color(1, 0.4, 0.7)))

	# Stat bars row (one per stat, 4 stats).
	var stats := GridContainer.new()
	stats.columns = 2
	stats.add_theme_constant_override(&"h_separation", 16)
	stats.add_theme_constant_override(&"v_separation", 4)
	col.add_child(stats)

	stats.add_child(_make_stat_bar("DMG",     int(wpn.damage),       0, 150, Color(1, 0.4, 0.35)))
	stats.add_child(_make_stat_bar("MAG",     wpn.magazine,           1, 60,  Color(0.5, 0.85, 1)))
	# Lower fire_interval is FASTER → invert for visual "fire rate" bar.
	var rof_inv: int = clampi(int(round(1500.0 - wpn.fire_interval_ms)), 0, 1500)
	stats.add_child(_make_stat_bar("ROF",     rof_inv,                0, 1500, Color(1, 0.85, 0.4)))
	var bspeed: int = 999 if wpn.is_hitscan() else int(wpn.bullet_speed)
	stats.add_child(_make_stat_bar("SPEED",   bspeed,                 60, 300, Color(0.6, 1, 0.7)))

	# Ability callout.
	if wpn.ability != null and not String(wpn.ability.name).is_empty():
		var ability_box := PanelContainer.new()
		var abox := StyleBoxFlat.new()
		abox.bg_color = Color(0.05, 0.1, 0.18, 0.7)
		abox.border_color = Color(0.5, 0.85, 1, 0.5)
		abox.border_width_left = 3
		abox.corner_radius_top_left = 4
		abox.corner_radius_top_right = 4
		abox.corner_radius_bottom_left = 4
		abox.corner_radius_bottom_right = 4
		abox.content_margin_left = 10
		abox.content_margin_right = 10
		abox.content_margin_top = 6
		abox.content_margin_bottom = 6
		ability_box.add_theme_stylebox_override(&"panel", abox)
		var avbox := VBoxContainer.new()
		avbox.add_theme_constant_override(&"separation", 2)
		ability_box.add_child(avbox)
		var ah := Label.new()
		ah.text = "⚡ %s" % wpn.ability.name
		ah.add_theme_color_override(&"font_color", Color(0.55, 0.95, 1))
		ah.add_theme_font_size_override(&"font_size", 13)
		avbox.add_child(ah)
		if not String(wpn.ability.description).is_empty():
			var ad := Label.new()
			ad.text = wpn.ability.description
			ad.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			ad.custom_minimum_size = Vector2(620, 0)
			ad.add_theme_font_size_override(&"font_size", 12)
			ad.add_theme_color_override(&"font_color", Color(0.85, 0.92, 1))
			avbox.add_child(ad)
		col.add_child(ability_box)

	# Description.
	if "description" in wpn and not wpn.description.is_empty():
		var desc := Label.new()
		desc.text = wpn.description
		desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		desc.custom_minimum_size = Vector2(640, 0)
		desc.add_theme_font_size_override(&"font_size", 12)
		desc.add_theme_color_override(&"font_color", Color(0.78, 0.85, 0.95))
		col.add_child(desc)

	# ── Upgrade row: three "+ Upgrade" buttons (damage / mag / reload).
	col.add_child(_make_upgrade_row(String(wpn.id), settings, on_upgrade))

	return card


# Upgrade row added to every weapon card. Reads current level from
# Settings.upgrades and shows "DMG L3/10  +5 碎片" buttons. Click → invokes
# the on_upgrade Callable supplied by the caller (main_menu fires the
# request_apply_upgrade RPC; the resulting profile push refreshes the dialog
# next open).
static func _make_upgrade_row(weapon_id: String, settings: Node, on_upgrade: Callable) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 8)
	var upgrades: Dictionary = {}
	if settings != null and "upgrades" in settings:
		var all: Dictionary = settings.upgrades
		upgrades = all.get(weapon_id, {})
	for stat in ["damage", "mag", "reload"]:
		var lvl: int = int(upgrades.get(stat, 0))
		var btn := Button.new()
		var stat_label: String = {"damage": "DMG", "mag": "MAG", "reload": "RLD"}[stat]
		if lvl >= 10:
			btn.text = "%s ★ MAX" % stat_label
			btn.disabled = true
		else:
			btn.text = "%s  L%d/10  +5 碎片" % [stat_label, lvl]
		btn.custom_minimum_size = Vector2(170, 32)
		btn.add_theme_font_size_override(&"font_size", 13)
		btn.add_theme_color_override(&"font_color", Color(0.85, 0.95, 0.55) if lvl < 10 else Color(0.95, 0.7, 0.3))
		var captured_stat: String = stat
		var captured_lvl: int = lvl
		btn.pressed.connect(func(): on_upgrade.call(weapon_id, captured_stat, captured_lvl + 1))
		row.add_child(btn)
	return row


static func _make_badge(text: String, color: Color) -> PanelContainer:
	var pc := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(color.r * 0.25, color.g * 0.25, color.b * 0.25, 0.85)
	s.border_color = color
	s.border_width_left = 1
	s.border_width_right = 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.corner_radius_top_left = 4
	s.corner_radius_top_right = 4
	s.corner_radius_bottom_left = 4
	s.corner_radius_bottom_right = 4
	s.content_margin_left = 8
	s.content_margin_right = 8
	s.content_margin_top = 2
	s.content_margin_bottom = 2
	pc.add_theme_stylebox_override(&"panel", s)
	var l := Label.new()
	l.text = text
	l.add_theme_color_override(&"font_color", color)
	l.add_theme_font_size_override(&"font_size", 11)
	pc.add_child(l)
	return pc


static func _make_stat_bar(label: String, value: int, min_v: int, max_v: int, color: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 8)
	row.custom_minimum_size = Vector2(310, 0)

	var name_lbl := Label.new()
	name_lbl.text = label
	name_lbl.custom_minimum_size = Vector2(48, 0)
	name_lbl.add_theme_font_size_override(&"font_size", 11)
	name_lbl.add_theme_color_override(&"font_color", Color(0.55, 0.78, 0.95, 0.85))
	row.add_child(name_lbl)

	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(180, 12)
	bar.min_value = min_v
	bar.max_value = max_v
	bar.value = clamp(value, min_v, max_v)
	bar.show_percentage = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.04, 0.07, 0.13, 1)
	bg.border_color = Color(0.3, 0.55, 0.85, 0.4)
	bg.border_width_left = 1
	bg.border_width_right = 1
	bg.border_width_top = 1
	bg.border_width_bottom = 1
	bg.corner_radius_top_left = 4
	bg.corner_radius_top_right = 4
	bg.corner_radius_bottom_left = 4
	bg.corner_radius_bottom_right = 4
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.corner_radius_top_left = 3
	fill.corner_radius_top_right = 3
	fill.corner_radius_bottom_left = 3
	fill.corner_radius_bottom_right = 3
	bar.add_theme_stylebox_override(&"background", bg)
	bar.add_theme_stylebox_override(&"fill", fill)
	row.add_child(bar)

	var val_lbl := Label.new()
	val_lbl.text = "%d" % value if value < 999 else "∞"
	val_lbl.custom_minimum_size = Vector2(40, 0)
	val_lbl.add_theme_font_size_override(&"font_size", 12)
	val_lbl.add_theme_color_override(&"font_color", color)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(val_lbl)

	return row


static func _weapon_card_style(wpn: Resource) -> StyleBoxFlat:
	# Highlight admin / instakill weapons with a warmer border so they pop.
	# wpn is typed as Resource (not WeaponDef) so we need an explicit type
	# annotation — GDScript can't infer bullet_color from a base Resource.
	var c: Color = Color(0.5, 0.85, 1, 0.6)
	if "bullet_color" in wpn:
		c = wpn.bullet_color
	c.a = 0.55
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.05, 0.08, 0.15, 0.92)
	s.border_color = c
	s.border_width_left = 2
	s.border_width_top = 2
	s.border_width_right = 2
	s.border_width_bottom = 2
	s.corner_radius_top_left = 10
	s.corner_radius_top_right = 10
	s.corner_radius_bottom_left = 10
	s.corner_radius_bottom_right = 10
	s.shadow_color = Color(0, 0, 0, 0.4)
	s.shadow_size = 6
	return s
