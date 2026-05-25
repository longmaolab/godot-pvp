extends CanvasLayer
class_name HUD

const FEED_MAX_LINES := 6
const FEED_LIFETIME_SEC := 6.0

@onready var hp_label: Label = $TopLeft/HpV/HpRow/HpLabel
@onready var hp_bar: ProgressBar = $TopLeft/HpV/HpBar
@onready var weapon_name_label: Label = $BottomRight/AmmoV/WeaponName
@onready var ammo_label: Label = $BottomRight/AmmoV/AmmoLabel
@onready var feed: VBoxContainer = $BottomLeft/Feed
@onready var hit_flash: ColorRect = $HitFlash
@onready var damage_vignette: TextureRect = $DamageVignette
@onready var round_timer: Label = $TopCenter/RoundTimer
@onready var mode_badge: Label = $TopCenter/ModeBadge
@onready var hit_marker: Control = $Crosshair/HitMarker
@onready var kill_confirm: Label = $KillConfirm
@onready var resume_prompt: Control = $ResumePrompt
@onready var credits_pill: Label = $CreditsPill
@onready var ability_bar: ProgressBar = $AbilityIndicator/AbilityBar
@onready var ability_label: Label = $AbilityIndicator/AbilityLabel
var _ability_player: Node = null

# Track HP delta so we can flash the screen red exactly when damage lands.
var _last_hp: float = -1.0

# Reusable style for feed row backgrounds (cheap — one shared sub-resource).
var _feed_row_style: StyleBoxFlat


func _ready() -> void:
	set_process(true)   # for the resume-prompt visibility poll
	_feed_row_style = StyleBoxFlat.new()
	# Bind the credits pill to the Settings autoload so kills update it live.
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		_update_credits(s.credits)
		s.credits_changed.connect(_update_credits)
	_feed_row_style.bg_color = Color(0.05, 0.09, 0.16, 0.78)
	_feed_row_style.border_color = Color(0.4, 0.78, 1, 0.4)
	_feed_row_style.border_width_left = 2
	_feed_row_style.corner_radius_top_left = 6
	_feed_row_style.corner_radius_top_right = 6
	_feed_row_style.corner_radius_bottom_left = 6
	_feed_row_style.corner_radius_bottom_right = 6
	_feed_row_style.content_margin_left = 10
	_feed_row_style.content_margin_right = 10
	_feed_row_style.content_margin_top = 6
	_feed_row_style.content_margin_bottom = 6


func bind_player(player: Node) -> void:
	if player == null:
		return
	_ability_player = player
	if player.has_signal(&"hp_changed"):
		player.hp_changed.connect(_on_hp_changed)
	if player.has_signal(&"ammo_changed"):
		player.ammo_changed.connect(_on_ammo_changed)
	if player.has_signal(&"weapon_switched"):
		player.weapon_switched.connect(_on_weapon_switched)
	if player.has_signal(&"died"):
		player.died.connect(_on_died)
	if player.weapon_def != null:
		_on_weapon_switched(player.weapon_def)


func _on_weapon_switched(new_weapon: Resource) -> void:
	if new_weapon == null:
		return
	weapon_name_label.text = "%s   ·   %s" % [new_weapon.display_name, new_weapon.type_label]
	push_feed("equipped %s" % new_weapon.display_name, Color(0.6, 0.95, 1.0))


func _on_hp_changed(new_hp: float, max_hp: float) -> void:
	hp_label.text = "HP %d / %d" % [int(new_hp), int(max_hp)]
	hp_bar.max_value = max_hp
	hp_bar.value = new_hp
	# Color-tier the bar fill: green > 60% / amber 30-60% / red below 30%.
	# Mirrors arena-shooter-3d/scripts/hud.gd's color scheme.
	var hp_ratio: float = new_hp / maxf(max_hp, 1.0)
	var fill_box: StyleBoxFlat = hp_bar.get_theme_stylebox(&"fill") as StyleBoxFlat
	if fill_box != null:
		if hp_ratio > 0.6:
			fill_box.bg_color = Color(0.16, 0.85, 0.4, 1)
		elif hp_ratio > 0.3:
			fill_box.bg_color = Color(0.95, 0.78, 0.25, 1)
		else:
			fill_box.bg_color = Color(0.95, 0.28, 0.28, 1)
	# Damage-drop flash + continuous low-HP vignette.
	if _last_hp >= 0.0 and new_hp < _last_hp - 0.5:
		_flash_take_damage()
	_last_hp = new_hp
	if hp_ratio < 0.35 and damage_vignette != null:
		damage_vignette.modulate.a = clampf(1.0 - hp_ratio * 2.0, 0.0, 0.75)
	else:
		damage_vignette.modulate.a = 0.0


func _flash_take_damage() -> void:
	hit_flash.color = Color(1.0, 0.15, 0.2, 0.55)
	hit_flash.visible = true
	var t: Tween = create_tween()
	t.tween_property(hit_flash, "color:a", 0.0, 0.32)
	t.tween_callback(func():
		if is_instance_valid(hit_flash):
			hit_flash.visible = false)
	_play_audio(&"play_take_damage")


func _on_ammo_changed(in_mag: int, reserve: int) -> void:
	ammo_label.text = "%d / %d" % [in_mag, reserve]


func _on_died(_killer: Node) -> void:
	push_feed("YOU DIED", Color(1, 0.3, 0.3))


## Hit marker pulse — the 4 diagonal ticks around the crosshair flash white
## (yellow on headshot) and expand outward. Way more visible than a tiny
## screen tint, and doesn't compete with the take-damage red flash.
func flash_hit(headshot: bool) -> void:
	if hit_marker == null:
		return
	var color: Color = Color(1, 0.85, 0.2, 1.0) if headshot else Color(1, 1, 1, 1.0)
	hit_marker.modulate = color
	hit_marker.scale = Vector2(0.7, 0.7)
	hit_marker.pivot_offset = hit_marker.size * 0.5
	var t: Tween = create_tween()
	t.set_parallel(true)
	t.tween_property(hit_marker, "scale", Vector2(1.3, 1.3), 0.18)
	t.tween_property(hit_marker, "modulate:a", 0.0, 0.32)
	t.chain().tween_callback(func():
		if is_instance_valid(hit_marker):
			hit_marker.scale = Vector2.ONE)
	_play_audio(&"play_hitmarker")


## Push a kill-feed line. Each entry is a small left-bordered panel; older
## lines are auto-removed when count exceeds FEED_MAX_LINES.
func push_feed(text: String, color: Color = Color.WHITE) -> void:
	var pc := PanelContainer.new()
	pc.add_theme_stylebox_override(&"panel", _feed_row_style)
	var label := Label.new()
	label.text = text
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_font_size_override(&"font_size", 14)
	pc.add_child(label)
	feed.add_child(pc)
	# remove_child takes effect immediately; queue_free alone would not — the
	# child stays in the tree until end of frame, so get_child_count wouldn't
	# drop and this loop would spin forever (= "Godot 未响应").
	while feed.get_child_count() > FEED_MAX_LINES:
		var old: Node = feed.get_child(0)
		feed.remove_child(old)
		old.queue_free()
	# If we're mid scene-teardown (e.g. match ended → swapping to room_lobby)
	# the HUD node may have detached from the tree before this push_feed call
	# arrives. get_tree() returns null in that state and create_timer crashes.
	# Bail cleanly — the feed line we added above will get freed with the
	# whole HUD anyway.
	if not is_inside_tree():
		return
	# test.md Bug C: capture instance_id (int) instead of the Node so that if
	# the feed line is freed early (e.g. scene teardown or FEED_MAX_LINES
	# pushes it out), Godot doesn't dump
	# `ERROR: Lambda capture at index 0 was freed. Passed "null" instead.`
	# when the timer fires. is_instance_valid + instance_from_id is the
	# nullable lookup.
	var pc_id: int = pc.get_instance_id()
	get_tree().create_timer(FEED_LIFETIME_SEC).timeout.connect(
		func():
			var node: Object = instance_from_id(pc_id)
			if node != null and is_instance_valid(node):
				node.queue_free()
	)


## Set round timer text from outside (MatchController plug-in point).
func set_round_timer(seconds_left: float) -> void:
	if seconds_left <= 0.0:
		round_timer.text = ""
		return
	var s: int = int(ceil(seconds_left))
	@warning_ignore("integer_division")
	var mins: int = s / 60
	round_timer.text = "%d:%02d" % [mins, s % 60]


func set_mode_badge(text: String) -> void:
	mode_badge.text = text


func _update_credits(new_total: int) -> void:
	if credits_pill != null:
		credits_pill.text = "💰 %d" % new_total


## Ability cooldown bar — polled each frame.
## (The "Click to resume" overlay was retired; pause_menu now auto-opens on
## mouse-loss so the user always lands on the same UI no matter how capture
## was broken — ESC, alt-tab, browser pointer-lock release.)
func _process(_delta: float) -> void:
	if resume_prompt != null and resume_prompt.visible:
		resume_prompt.visible = false
	# Ability cooldown bar — derived live from the local player's state.
	if _ability_player != null and is_instance_valid(_ability_player) \
			and ability_bar != null and ability_label != null:
		if _ability_player.weapon_def == null or _ability_player.weapon_def.ability == null:
			ability_label.text = "Q · no ability"
			ability_bar.value = 0.0
			return
		var a: Resource = _ability_player.weapon_def.ability
		var cd_total: float = float(a.cooldown_ms) / 1000.0
		var now_s: float = Time.get_ticks_msec() / 1000.0
		var until: float = _ability_player._ability_cooldown_until
		if until <= now_s:
			ability_bar.value = 1.0
			ability_label.text = "Q · %s  READY" % a.name
		else:
			var remaining: float = until - now_s
			ability_bar.value = clampf(1.0 - remaining / cd_total, 0.0, 1.0)
			ability_label.text = "Q · %s  %.1fs" % [a.name, remaining]


## Tiered kill-streak announcer. Each successive kill within STREAK_RESET_SEC
## of the last bumps the streak counter; the announcement banner escalates
## through DOUBLE / TRIPLE / RAMPAGE / GODLIKE with color progression.
const STREAK_RESET_SEC := 4.5
const STREAK_TIERS := [
	{"count": 2, "label": "DOUBLE KILL",  "color": Color(1, 0.85, 0.35)},
	{"count": 3, "label": "TRIPLE KILL",  "color": Color(1, 0.55, 0.25)},
	{"count": 5, "label": "RAMPAGE",      "color": Color(1, 0.30, 0.30)},
	{"count": 7, "label": "GODLIKE",      "color": Color(0.85, 0.45, 1)},
]
var _streak_count: int = 0
var _streak_last_kill_ms: int = -10000


## Big screen-center "ELIMINATED" pop when local player drops an enemy.
## Also tracks streak counter and triggers escalation banners.
func show_kill_confirm(victim_name: String) -> void:
	if kill_confirm == null:
		return
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _streak_last_kill_ms < int(STREAK_RESET_SEC * 1000):
		_streak_count += 1
	else:
		_streak_count = 1
	_streak_last_kill_ms = now_ms

	# Pick streak label if this kill crossed a tier threshold.
	var streak_label: String = ""
	var streak_color: Color = Color(1, 0.95, 0.4, 1)
	for tier in STREAK_TIERS:
		if _streak_count >= tier["count"]:
			streak_label = tier["label"]
			streak_color = tier["color"]

	if streak_label != "":
		kill_confirm.text = "★ %s ★" % streak_label
		kill_confirm.modulate = streak_color
		kill_confirm.modulate.a = 1.0
	else:
		kill_confirm.text = "★ ELIMINATED ★"
		kill_confirm.modulate = Color(1, 0.95, 0.4, 1)
	kill_confirm.scale = Vector2(0.55, 0.55)
	var t: Tween = create_tween()
	t.set_parallel(true)
	t.tween_property(kill_confirm, "scale", Vector2(1.15, 1.15), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(kill_confirm, "modulate:a", 1.0, 0.05)
	t.chain().tween_interval(0.55)
	t.chain().tween_property(kill_confirm, "modulate:a", 0.0, 0.25)
	push_feed("💀  killed %s%s" % [victim_name, "" if streak_label == "" else "  ·  " + streak_label],
		Color(1, 0.6, 0.4))
	_play_audio(&"play_kill")


# ── Hit sounds — try ProcAudio autoload if present, no-op otherwise. ──────
func _play_audio(method: StringName) -> void:
	var node: Node = get_node_or_null(^"/root/ProcAudio")
	if node != null and node.has_method(method):
		node.call(method)
