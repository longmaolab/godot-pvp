extends CanvasLayer
class_name AdminPanel
## F2 cheat / admin panel. 5 toggles + 4 instant-action buttons. Tracks down
## the local player + game_controller via the scene tree.
##
## Modeled on /Users/longmao/projects/pvp-game/public/game.js's F2 admin
## panel (fly / god / infammo / speed / freeze + heal / ammo / nuke / win).

@onready var fly_btn: CheckButton = $Card/V/FlyBtn
@onready var god_btn: CheckButton = $Card/V/GodBtn
@onready var inf_ammo_btn: CheckButton = $Card/V/InfAmmoBtn
@onready var speed_btn: CheckButton = $Card/V/SpeedBtn
@onready var freeze_btn: CheckButton = $Card/V/FreezeBtn
@onready var heal_btn: Button = $Card/V/HealBtn
@onready var ammo_btn: Button = $Card/V/AmmoBtn
@onready var nuke_btn: Button = $Card/V/NukeBtn
@onready var credits_btn: Button = $Card/V/CreditsBtn
@onready var players_list: VBoxContainer = $Card/V/PlayersList


func _ready() -> void:
	fly_btn.toggled.connect(_on_fly)
	god_btn.toggled.connect(_on_god)
	inf_ammo_btn.toggled.connect(_on_inf_ammo)
	speed_btn.toggled.connect(_on_speed)
	freeze_btn.toggled.connect(_on_freeze)
	heal_btn.pressed.connect(_on_heal)
	ammo_btn.pressed.connect(_on_ammo)
	nuke_btn.pressed.connect(_on_nuke)
	credits_btn.pressed.connect(_on_credits)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_F2: visible = not visible
		KEY_H:  fly_btn.button_pressed = not fly_btn.button_pressed
		KEY_J:  god_btn.button_pressed = not god_btn.button_pressed
		KEY_L:  inf_ammo_btn.button_pressed = not inf_ammo_btn.button_pressed
		KEY_N:  speed_btn.button_pressed = not speed_btn.button_pressed
		KEY_M:  freeze_btn.button_pressed = not freeze_btn.button_pressed


func _local() -> Node:
	var gc: Node = get_tree().root.get_node_or_null(^"Game")
	if gc != null and "local_player" in gc:
		return gc.local_player
	return null


func _game_controller() -> Node:
	return get_tree().root.get_node_or_null(^"Game")


func _on_fly(v: bool) -> void:
	var p: Node = _local()
	if p == null:
		return
	# Fly = ignore gravity. We park the multiplier near zero so other
	# code paths (like jump pads) still see "true" via the variable.
	p.gravity_multiplier = 0.02 if v else 1.0


func _on_god(v: bool) -> void:
	var p: Node = _local()
	if p == null:
		return
	# 1 hour window when god is on, expires immediately when off.
	p._invincible_until = (Time.get_ticks_msec() / 1000.0 + 3600.0) if v else 0.0


var _inf_ammo_polling: bool = false


func _on_inf_ammo(v: bool) -> void:
	_inf_ammo_polling = v


func _process(_delta: float) -> void:
	# Infinite ammo cheat — refill mag every frame.
	if _inf_ammo_polling:
		var p: Node = _local()
		if p != null and "weapon_def" in p and p.weapon_def != null:
			p.ammo_in_mag = p.weapon_def.magazine
			p.ammo_reserve = p.weapon_def.reserve
	# Refresh player list 4x/sec while the panel is visible. Cheap enough
	# (just a few labels) that we don't bother with diffing.
	if visible:
		_refresh_players_list()


var _player_list_accum: float = 0.0


func _refresh_players_list() -> void:
	# Throttle to ~4 Hz so we don't rebuild the layout every frame.
	_player_list_accum += get_process_delta_time()
	if _player_list_accum < 0.25:
		return
	_player_list_accum = 0.0
	var gc: Node = _game_controller()
	if gc == null or not "players_by_peer" in gc:
		return
	# Wipe previous rows.
	for child in players_list.get_children():
		child.queue_free()
	var local: Node = _local()
	for peer in gc.players_by_peer.keys():
		var p: Node = gc.players_by_peer[peer]
		if p == null or not is_instance_valid(p):
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 6)
		var name_str: String = String(p.player_name) if "player_name" in p else "Peer %d" % peer
		var hp_str: String = "HP %d/%d" % [int(p.hp) if "hp" in p else 0, int(p.max_hp) if "max_hp" in p else 0]
		var weapon_str: String = String(p.weapon_def.id) if "weapon_def" in p and p.weapon_def != null else "—"
		var lbl := Label.new()
		# Show YOU marker for local.
		var prefix: String = "★ " if p == local else "  "
		lbl.text = "%s%s · %s · %s" % [prefix, name_str, hp_str, weapon_str]
		lbl.add_theme_font_size_override(&"font_size", 11)
		# Dead = greyed out, alive = white-ish, local = yellow.
		var col: Color = Color(0.55, 0.55, 0.55)
		if "is_dead" in p and not p.is_dead:
			col = Color(0.85, 0.85, 0.95) if p != local else Color(1, 0.85, 0.4)
		lbl.add_theme_color_override(&"font_color", col)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)
		# Teleport-to button — only meaningful for non-local players.
		if p != local:
			var tp := Button.new()
			tp.text = "TP"
			tp.tooltip_text = "Teleport local player to this player"
			tp.add_theme_font_size_override(&"font_size", 10)
			tp.custom_minimum_size = Vector2(36, 0)
			var captured: Node = p
			tp.pressed.connect(func(): _teleport_to(captured))
			row.add_child(tp)
		players_list.add_child(row)


func _teleport_to(target: Node) -> void:
	var p: Node = _local()
	if p == null or target == null or not is_instance_valid(target):
		return
	# Stand 2m behind the target so you don't spawn inside them.
	var fwd: Vector3 = -target.transform.basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3(0, 0, 1)
	p.global_position = target.global_position - fwd * 2.0 + Vector3(0, 0.5, 0)


func _on_speed(v: bool) -> void:
	var p: Node = _local()
	if p == null:
		return
	p.move_speed_multiplier = 3.0 if v else 1.0


func _on_freeze(v: bool) -> void:
	var gc: Node = _game_controller()
	if gc == null or not "bots" in gc:
		return
	for b in gc.bots:
		if is_instance_valid(b) and "target" in b:
			b.set_process(not v)
			b.set_physics_process(not v)


func _on_heal() -> void:
	var p: Node = _local()
	if p == null:
		return
	p.hp = p.max_hp
	p.hp_changed.emit(p.hp, p.max_hp)


func _on_ammo() -> void:
	var p: Node = _local()
	if p == null:
		return
	for w in p.loadout:
		if w != null:
			p._ammo_state[w.id] = {"in_mag": w.magazine, "reserve": w.reserve}
	if p.weapon_def != null:
		p._sync_ammo_from_state()


func _on_nuke() -> void:
	var gc: Node = _game_controller()
	if gc == null or not "bots" in gc:
		return
	for b in gc.bots:
		if is_instance_valid(b) and b.has_method(&"apply_damage"):
			b.apply_damage(99999.0, _local())


func _on_credits() -> void:
	if has_node(^"/root/Settings"):
		get_node(^"/root/Settings").award_credits(1000)
