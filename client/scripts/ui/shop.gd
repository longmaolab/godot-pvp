extends Control
class_name ShopScreen
## Full-screen shop modeled on /Users/longmao/projects/pvp-game's economy UI.
## 4 tabs: Weapons / Chests / Wheel / Upgrades. All transactions go through
## the Settings autoload (credits / fragments / purchased / upgrades).

const COMMON_CHEST_PRICE := 120
const RARE_CHEST_PRICE := 400
const WHEEL_PAID_PRICE := 100
const FRAGMENT_UNLOCK_COST := 100
const MAIN_MENU := preload("res://client/scenes/main_menu.tscn")

@onready var credits_label: Label = $V/Header/H/Credits
@onready var fragments_label: Label = $V/Header/H/Fragments
@onready var back_btn: Button = $V/Header/H/BackButton
@onready var tabs: TabContainer = $V/Tabs
@onready var weapons_list: VBoxContainer = $V/Tabs/Weapons/Scroll/V
@onready var common_chest_btn: Button = $V/Tabs/Chests/V/CommonRow/H/BuyOpen
@onready var rare_chest_btn: Button = $V/Tabs/Chests/V/RareRow/H/BuyOpen
@onready var common_chest_count: Label = $V/Tabs/Chests/V/CommonRow/H/Count
@onready var rare_chest_count: Label = $V/Tabs/Chests/V/RareRow/H/Count
@onready var common_chest_buy: Button = $V/Tabs/Chests/V/CommonRow/H/Buy
@onready var rare_chest_buy: Button = $V/Tabs/Chests/V/RareRow/H/Buy
@onready var wheel_spin_btn: Button = $V/Tabs/Wheel/V/SpinButton
@onready var wheel_hint: Label = $V/Tabs/Wheel/V/Hint
@onready var wheel_dial: Control = $V/Tabs/Wheel/V/DialHolder/Dial
@onready var wheel_result: RichTextLabel = $V/Tabs/Wheel/V/Result
@onready var upgrades_list: VBoxContainer = $V/Tabs/Upgrades/Scroll/V
@onready var bundles_list: VBoxContainer = $V/Tabs/Bundles/Scroll/V
@onready var reveal_dialog: AcceptDialog = $RevealDialog
@onready var reveal_text: RichTextLabel = $RevealDialog/Text


func _ready() -> void:
	back_btn.pressed.connect(_on_back)
	common_chest_btn.pressed.connect(_on_open_chest.bind(&"common"))
	rare_chest_btn.pressed.connect(_on_open_chest.bind(&"rare"))
	common_chest_buy.pressed.connect(_on_buy_chest.bind(&"common"))
	rare_chest_buy.pressed.connect(_on_buy_chest.bind(&"rare"))
	wheel_spin_btn.pressed.connect(_on_spin)
	_refresh_currency()
	_populate_weapons()
	_populate_upgrades()
	_populate_bundles()
	_refresh_chests()
	_refresh_wheel_hint()
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		s.credits_changed.connect(func(_n): _refresh_currency())
		s.fragments_changed.connect(func(_n): _refresh_currency())
		s.chests_changed.connect(_refresh_chests)
		s.purchased_changed.connect(_populate_weapons)
		s.purchased_changed.connect(_populate_bundles)
		s.upgrades_changed.connect(_populate_upgrades)


# ── Bundles tab ───────────────────────────────────────────────────────────
func _populate_bundles() -> void:
	for c in bundles_list.get_children():
		c.queue_free()
	var dir := DirAccess.open("res://shared/data/bundles/")
	if dir == null:
		return
	var bundles: Array = []
	dir.list_dir_begin()
	while true:
		var fname: String = dir.get_next()
		if fname == "":
			break
		# Web export rewrites .tres → .tres.remap. Strip so load() resolves.
		if fname.ends_with(".tres.remap"):
			fname = fname.substr(0, fname.length() - 6)
		if dir.current_is_dir() or fname.begins_with("_") or not fname.ends_with(".tres"):
			continue
		var res: Resource = load("res://shared/data/bundles/" + fname)
		if res != null:
			bundles.append(res)
	dir.list_dir_end()
	bundles.sort_custom(func(a, b): return a.price_credits < b.price_credits)
	for b in bundles:
		bundles_list.add_child(_make_bundle_card(b))


func _make_bundle_card(b: Resource) -> PanelContainer:
	var s: Node = get_node(^"/root/Settings")
	var pc := PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.08, 0.14, 0.92)
	bg.border_color = b.theme_color if "theme_color" in b else Color(0.4, 0.7, 0.95, 0.6)
	bg.border_width_left = 3
	bg.border_width_top = 2
	bg.border_width_right = 2
	bg.border_width_bottom = 2
	bg.corner_radius_top_left = 10
	bg.corner_radius_top_right = 10
	bg.corner_radius_bottom_left = 10
	bg.corner_radius_bottom_right = 10
	bg.content_margin_left = 16
	bg.content_margin_right = 16
	bg.content_margin_top = 12
	bg.content_margin_bottom = 12
	pc.add_theme_stylebox_override(&"panel", bg)
	var v := VBoxContainer.new()
	v.add_theme_constant_override(&"separation", 6)
	pc.add_child(v)
	var header := HBoxContainer.new()
	v.add_child(header)
	var title := Label.new()
	title.text = "★" + b.display_name
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override(&"font_size", 20)
	title.add_theme_color_override(&"font_color", b.theme_color)
	header.add_child(title)
	var savings_lbl := Label.new()
	savings_lbl.text = "省 %d$" % b.savings()
	savings_lbl.add_theme_color_override(&"font_color", Color(0.5, 1, 0.5))
	savings_lbl.add_theme_font_size_override(&"font_size", 13)
	header.add_child(savings_lbl)
	var desc := Label.new()
	desc.text = b.description
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.add_theme_font_size_override(&"font_size", 12)
	desc.add_theme_color_override(&"font_color", Color(0.78, 0.88, 0.96))
	v.add_child(desc)
	var items_row := HBoxContainer.new()
	items_row.add_theme_constant_override(&"separation", 8)
	for w in b.items:
		if w == null:
			continue
		var chip := Label.new()
		var prefix: String = "✓" if s.is_owned(String(w.id)) else ""
		chip.text = "%s%s" % [prefix, w.display_name]
		chip.add_theme_font_size_override(&"font_size", 11)
		var col: Color = Color(0.55, 0.75, 0.55) if s.is_owned(String(w.id)) else Color(1, 0.85, 0.4)
		chip.add_theme_color_override(&"font_color", col)
		items_row.add_child(chip)
	v.add_child(items_row)
	var buy_row := HBoxContainer.new()
	v.add_child(buy_row)
	var price_lbl := Label.new()
	price_lbl.text = "总价 $%d (单买 $%d)" % [b.price_credits, b.full_price()]
	price_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	price_lbl.add_theme_color_override(&"font_color", Color(0.7, 0.85, 0.95))
	price_lbl.add_theme_font_size_override(&"font_size", 12)
	buy_row.add_child(price_lbl)
	var buy_btn := Button.new()
	buy_btn.custom_minimum_size = Vector2(160, 32)
	var unowned: int = 0
	for w in b.items:
		if w != null and not s.is_owned(String(w.id)):
			unowned += 1
	if unowned == 0:
		buy_btn.text = "全部已拥有"
		buy_btn.disabled = true
	else:
		buy_btn.text = "BUY · $%d" % b.price_credits
		buy_btn.pressed.connect(_on_buy_bundle.bind(b))
	buy_row.add_child(buy_btn)
	return pc


func _on_buy_bundle(b: Resource) -> void:
	var s: Node = get_node(^"/root/Settings")
	if not s.spend_credits(b.price_credits):
		_reveal("[color=#ff8888]Not enough credits — need $%d, have $%d.[/color]" % [b.price_credits, s.credits])
		return
	var unlocked: Array = []
	for w in b.items:
		if w != null and not s.is_owned(String(w.id)):
			s.mark_purchased(String(w.id))
			unlocked.append(w.display_name)
	var msg: String = "[color=#ffd84a]★ %s purchased ★[/color]\n\n[color=#88ff88]Unlocked:[/color]\n" % b.display_name
	for n in unlocked:
		msg += "•" + n + "\n"
	_reveal(msg)


# ── Currency / nav ────────────────────────────────────────────────────────
func _on_back() -> void:
	get_tree().change_scene_to_packed(MAIN_MENU)


func _refresh_currency() -> void:
	if not has_node(^"/root/Settings"):
		return
	var s: Node = get_node(^"/root/Settings")
	credits_label.text = "$ %d" % s.credits
	fragments_label.text = "%d" % s.fragments


# ── Weapons tab ───────────────────────────────────────────────────────────
func _populate_weapons() -> void:
	for c in weapons_list.get_children():
		c.queue_free()
	var dir := DirAccess.open("res://shared/data/weapons/")
	if dir == null:
		return
	var entries: Array = []
	dir.list_dir_begin()
	while true:
		var fname: String = dir.get_next()
		if fname == "":
			break
		# Web export .tres.remap strip — see bundles loop above.
		if fname.ends_with(".tres.remap"):
			fname = fname.substr(0, fname.length() - 6)
		if dir.current_is_dir() or fname.begins_with("_") or not fname.ends_with(".tres"):
			continue
		var res: Resource = load("res://shared/data/weapons/" + fname)
		if res != null:
			entries.append(res)
	dir.list_dir_end()
	# Free first, then cheapest, then ascending by price.
	entries.sort_custom(func(a, b):
		if a.free_starter != b.free_starter:
			return a.free_starter
		return a.price_credits < b.price_credits)
	for w in entries:
		weapons_list.add_child(_make_weapon_row(w))


func _make_weapon_row(w: Resource) -> PanelContainer:
	var s: Node = get_node(^"/root/Settings")
	var pc := PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.08, 0.14, 0.85)
	bg.border_color = Color(0.4, 0.7, 0.95, 0.4)
	bg.border_width_left = 2
	bg.corner_radius_top_left = 6
	bg.corner_radius_top_right = 6
	bg.corner_radius_bottom_left = 6
	bg.corner_radius_bottom_right = 6
	bg.content_margin_left = 12
	bg.content_margin_right = 12
	bg.content_margin_top = 8
	bg.content_margin_bottom = 8
	pc.add_theme_stylebox_override(&"panel", bg)
	var row := HBoxContainer.new()
	pc.add_child(row)

	var name_label := Label.new()
	name_label.text = "%s · %s · DMG %d" % [w.display_name, w.type_label, int(w.damage)]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override(&"font_size", 13)
	row.add_child(name_label)

	var price_label := Label.new()
	row.add_child(price_label)

	var buy_btn := Button.new()
	buy_btn.custom_minimum_size = Vector2(120, 28)
	row.add_child(buy_btn)

	if w.free_starter:
		price_label.text = "FREE"
		price_label.add_theme_color_override(&"font_color", Color(0.5, 1, 0.6))
		buy_btn.disabled = true
		buy_btn.text = "OWNED"
	elif w.admin_only:
		price_label.text = "ADMIN"
		price_label.add_theme_color_override(&"font_color", Color(1, 0.4, 0.7))
		buy_btn.disabled = true
		buy_btn.text = "locked"
	elif s.is_owned(w.id):
		price_label.text = "$ %d" % w.price_credits
		price_label.add_theme_color_override(&"font_color", Color(0.6, 0.8, 0.95))
		buy_btn.disabled = true
		buy_btn.text = "OWNED"
	else:
		price_label.text = "$ %d" % w.price_credits
		price_label.add_theme_color_override(&"font_color", Color(1, 0.85, 0.4))
		buy_btn.text = "BUY · $%d" % w.price_credits
		buy_btn.pressed.connect(_on_buy_weapon.bind(w))
	return pc


func _on_buy_weapon(w: Resource) -> void:
	var s: Node = get_node(^"/root/Settings")
	if not s.spend_credits(w.price_credits):
		_reveal("[color=#ff8888]Not enough credits![/color]\n你需要 $ %d，但只有 $ %d。" % [w.price_credits, s.credits])
		return
	s.mark_purchased(String(w.id))
	_reveal("[color=#a8ff88]Unlocked %s![/color]\n[color=#cccccc]%s[/color]\n\n按 1-4 切换武器时可选。" % [w.display_name, w.description])


# ── Chests tab ────────────────────────────────────────────────────────────
func _refresh_chests() -> void:
	var s: Node = get_node(^"/root/Settings")
	common_chest_count.text = "你有 %d 个" % s.common_chests
	rare_chest_count.text = "你有 %d 个" % s.rare_chests
	common_chest_btn.disabled = s.common_chests <= 0
	rare_chest_btn.disabled = s.rare_chests <= 0


func _on_buy_chest(kind: StringName) -> void:
	var s: Node = get_node(^"/root/Settings")
	var price: int = COMMON_CHEST_PRICE if kind == &"common" else RARE_CHEST_PRICE
	if not s.spend_credits(price):
		_reveal("[color=#ff8888]Not enough credits[/color]")
		return
	s.add_chest(kind, 1)
	_reveal("[color=#88ccff]+1 %s chest[/color]" % ("common" if kind == &"common" else "rare"))


func _on_open_chest(kind: StringName) -> void:
	var s: Node = get_node(^"/root/Settings")
	if not s.consume_chest(kind):
		return
	# Roll rewards. Common: small frags + maybe credits. Rare: bigger,
	# 5% chance of a free weapon unlock.
	var frags_won: int = randi_range(10, 25) if kind == &"common" else randi_range(35, 80)
	var creds_won: int = randi_range(0, 30) if kind == &"common" else randi_range(30, 100)
	s.award_fragments(frags_won)
	if creds_won > 0:
		s.award_credits(creds_won)
	var rare_unlock: String = ""
	if kind == &"rare" and randf() < 0.05:
		# Pick a random non-free non-admin weapon and unlock it.
		var pool: Array = []
		var d := DirAccess.open("res://shared/data/weapons/")
		if d != null:
			d.list_dir_begin()
			while true:
				var fname: String = d.get_next()
				if fname == "":
					break
				if fname.ends_with(".tres.remap"):
					fname = fname.substr(0, fname.length() - 6)
				if d.current_is_dir() or fname.begins_with("_") or not fname.ends_with(".tres"):
					continue
				var w: Resource = load("res://shared/data/weapons/" + fname)
				if w != null and not w.free_starter and not w.admin_only and not s.is_owned(w.id):
					pool.append(w)
			d.list_dir_end()
		if not pool.is_empty():
			var pick: Resource = pool[randi() % pool.size()]
			s.mark_purchased(String(pick.id))
			rare_unlock = pick.display_name
	_animate_chest_reveal(kind, frags_won, creds_won, rare_unlock)


func _animate_chest_reveal(kind: StringName, frags: int, creds: int, weapon_name: String) -> void:
	var lines: Array[String] = []
	lines.append("[center][color=#ffd84a]✦ %s CHEST ✦[/color][/center]" % \
		("COMMON" if kind == &"common" else "RARE"))
	lines.append("")
	lines.append("[color=#88ccff] +%d fragments[/color]" % frags)
	if creds > 0:
		lines.append("[color=#ffd84a]$ +%d credits[/color]" % creds)
	if weapon_name != "":
		lines.append("")
		lines.append("[color=#ff88dd]★ JACKPOT — unlocked %s! ★[/color]" % weapon_name)
	_reveal("\n".join(lines))


# ── Wheel tab ─────────────────────────────────────────────────────────────
func _refresh_wheel_hint() -> void:
	var s: Node = get_node(^"/root/Settings")
	if s.has_free_spin_today():
		wheel_spin_btn.text = "FREE SPIN"
		wheel_hint.text = "今日免费一次！明天后续转盘要 100$"
	else:
		wheel_spin_btn.text = "[D] SPIN · $%d" % WHEEL_PAID_PRICE
		wheel_hint.text = "免费转盘已用，需要 100$ 继续抽奖"


const WHEEL_OUTCOMES := [
	{"name": "jackpot",   "weight": 0.003, "label": "★ JACKPOT ★",        "color": "#ff88dd"},
	{"name": "big_bundle","weight": 0.007, "label": "* BIG BUNDLE",       "color": "#ffaa66"},
	{"name": "small_rare","weight": 0.05,  "label": "✨ small rare",       "color": "#aaff88"},
	{"name": "big_frags", "weight": 0.14,  "label": "×100 fragments",    "color": "#88ccff"},
	{"name": "frags",     "weight": 0.35,  "label": "×25 fragments",     "color": "#88aaee"},
	{"name": "credits",   "weight": 0.45,  "label": "$×80 credits",       "color": "#ffd84a"},
]


func _on_spin() -> void:
	var s: Node = get_node(^"/root/Settings")
	if s.has_free_spin_today():
		s.record_free_spin()
	else:
		if not s.spend_credits(WHEEL_PAID_PRICE):
			_reveal("[color=#ff8888]Need 100$ for paid spin[/color]")
			return
	wheel_spin_btn.disabled = true
	# Pick outcome.
	var r: float = randf()
	var cum: float = 0.0
	var picked: Dictionary = WHEEL_OUTCOMES[WHEEL_OUTCOMES.size() - 1]
	for o in WHEEL_OUTCOMES:
		cum += o["weight"]
		if r <= cum:
			picked = o
			break
	# Spin the dial — 5 full rotations + a random offset, 3.5s with cubic
	# bezier so it slows dramatically at the end.
	var target_rot: float = TAU * 5.0 + randf_range(0.0, TAU)
	wheel_dial.rotation = 0.0
	var t: Tween = create_tween()
	t.tween_property(wheel_dial, "rotation", target_rot, 3.5) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await t.finished
	_apply_wheel_outcome(picked, s)
	_refresh_wheel_hint()
	wheel_spin_btn.disabled = false


func _apply_wheel_outcome(o: Dictionary, s: Node) -> void:
	wheel_result.text = "[color=%s]%s[/color]" % [o["color"], o["label"]]
	wheel_result.bbcode_enabled = true
	wheel_result.text = "[center][color=%s]! %s[/color][/center]" % [o["color"], o["label"]]
	match o["name"]:
		"credits":    s.award_credits(80)
		"frags":      s.award_fragments(25)
		"big_frags":  s.award_fragments(100)
		"small_rare":
			s.award_fragments(40)
			s.award_credits(50)
		"big_bundle":
			s.award_fragments(150)
			s.award_credits(200)
		"jackpot":
			# 1 random non-owned weapon unlock.
			var pool: Array = []
			var d := DirAccess.open("res://shared/data/weapons/")
			if d != null:
				d.list_dir_begin()
				while true:
					var fn: String = d.get_next()
					if fn == "":
						break
					if fn.ends_with(".tres.remap"):
						fn = fn.substr(0, fn.length() - 6)
					if d.current_is_dir() or fn.begins_with("_") or not fn.ends_with(".tres"):
						continue
					var w: Resource = load("res://shared/data/weapons/" + fn)
					if w != null and not w.free_starter and not w.admin_only and not s.is_owned(w.id):
						pool.append(w)
				d.list_dir_end()
			if not pool.is_empty():
				var pick: Resource = pool[randi() % pool.size()]
				s.mark_purchased(String(pick.id))
				wheel_result.text += "\n[center][color=#ff88dd]Unlocked %s![/color][/center]" % pick.display_name


# ── Upgrades tab ──────────────────────────────────────────────────────────
func _populate_upgrades() -> void:
	for c in upgrades_list.get_children():
		c.queue_free()
	var s: Node = get_node(^"/root/Settings")
	var primary_ids: Array = ["ak20", "ak30", "sg8", "mp40", "rpd", "p90", "srx", "railgun", "crossbow"]
	for id in primary_ids:
		var w: Resource = load("res://shared/data/weapons/%s.tres" % id)
		if w == null:
			continue
		upgrades_list.add_child(_make_upgrade_row(w, s))


func _make_upgrade_row(w: Resource, s: Node) -> PanelContainer:
	var pc := PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.05, 0.08, 0.14, 0.85)
	bg.border_color = Color(0.6, 0.7, 0.95, 0.4)
	bg.border_width_left = 2
	bg.corner_radius_top_left = 6
	bg.corner_radius_top_right = 6
	bg.corner_radius_bottom_left = 6
	bg.corner_radius_bottom_right = 6
	bg.content_margin_left = 12
	bg.content_margin_right = 12
	bg.content_margin_top = 8
	bg.content_margin_bottom = 8
	pc.add_theme_stylebox_override(&"panel", bg)
	var row := HBoxContainer.new()
	pc.add_child(row)
	var name_label := Label.new()
	name_label.text = w.display_name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	for stat in [&"damage", &"mag", &"reload"]:
		var lvl: int = s.get_upgrade(String(w.id), stat)
		var btn := Button.new()
		var stat_label: String = "DMG" if stat == &"damage" else ("MAG" if stat == &"mag" else "RLD")
		btn.text = "%s lvl %d/3" % [stat_label, lvl]
		if lvl < 3:
			var cost: int = [30, 60, 120][lvl]
			btn.text += "%d" % cost
			btn.pressed.connect(func(): s.bump_upgrade(String(w.id), stat))
		else:
			btn.disabled = true
			btn.text += "MAX"
		btn.custom_minimum_size = Vector2(140, 28)
		row.add_child(btn)
	return pc


func _reveal(bbcode: String) -> void:
	reveal_text.text = bbcode
	reveal_dialog.popup_centered(Vector2i(520, 320))
