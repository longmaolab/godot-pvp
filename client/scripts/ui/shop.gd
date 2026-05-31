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
# Upgrade rule (level cap + per-level cost) — shared source of truth so Shop,
# the weapon catalog, and the server never drift. Preloaded class ref, not the
# autoload global, so this file also compiles in standalone --script loads.
const NetProtocol = preload("res://shared/scripts/network/net_protocol.gd")
const _PRIZE_WHEEL := preload("res://client/scripts/ui/prize_wheel.gd")
const _PRIZE_WHEEL_POINTER := preload("res://client/scripts/ui/prize_wheel_pointer.gd")
const _WHEEL_SIZE := Vector2(264, 264)
# Untyped (not `: PrizeWheel`) so shop.gd still parses under smoke's `--script`
# cold-cache load, where the class_name global isn't registered. Runtime is a
# real PrizeWheel; its methods dispatch dynamically.
var _wheel = null

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
@onready var wheel_holder: CenterContainer = $V/Tabs/Wheel/V/DialHolder
@onready var wheel_result: RichTextLabel = $V/Tabs/Wheel/V/Result
@onready var upgrades_list: VBoxContainer = $V/Tabs/Upgrades/Scroll/V
@onready var bundles_list: VBoxContainer = $V/Tabs/Bundles/Scroll/V
@onready var reveal_dialog: AcceptDialog = $RevealDialog
@onready var reveal_text: RichTextLabel = $RevealDialog/Text

# Captured at the moment a server-routed purchase RPC fires; consumed when the
# matching server_action_result lands so the success popup names the weapon
# the user clicked. (server_action_result only carries action+ok+reason, not
# the weapon id, so we have to remember on the client side.)
var _pending_weapon_unlock_name: String = ""
var _pending_weapon_unlock_desc: String = ""


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
	_build_wheel()
	# Header currency as rounded "pills" (gold credits / blue fragments).
	credits_label.add_theme_stylebox_override(&"normal", _pill_box(Color(1, 0.85, 0.4)))
	fragments_label.add_theme_stylebox_override(&"normal", _pill_box(Color(0.55, 0.8, 1.0)))
	# Chest rows live in the scene (not built procedurally) — give them the same
	# unified card look + button styling as the other tabs.
	_style_card(get_node(^"V/Tabs/Chests/V/CommonRow") as PanelContainer, _CARD_ACCENT)
	_style_card(get_node(^"V/Tabs/Chests/V/RareRow") as PanelContainer, Color(0.9, 0.5, 0.85, 0.55))
	for cb in [common_chest_buy, rare_chest_buy, common_chest_btn, rare_chest_btn]:
		_style_buy_button(cb)
	if has_node(^"/root/Settings"):
		var s: Node = get_node(^"/root/Settings")
		s.credits_changed.connect(func(_n): _refresh_currency())
		s.fragments_changed.connect(func(_n): _refresh_currency())
		s.chests_changed.connect(_refresh_chests)
		s.purchased_changed.connect(_populate_weapons)
		s.purchased_changed.connect(_populate_bundles)
		s.upgrades_changed.connect(_populate_upgrades)
		# Server reply for any mutating shop op (purchase / chest / wheel /
		# upgrade). We always re-enable the matching button here; success
		# refreshes happen via credits_changed / purchased_changed which
		# arrive together with the same server_profile push.
		s.server_action.connect(_on_server_action)
		s.reward_received.connect(_on_server_reward)


# Are we talking to a real server right now? `synced_with_server` flips after
# the server's first profile snapshot lands; once true, every mutation must
# route through an RPC (else the local change is overwritten on the next
# sync, the original P0 from review 09:00).
func _is_online() -> bool:
	if not has_node(^"/root/Settings"):
		return false
	return get_node(^"/root/Settings").synced_with_server


# ── Shared visual design (Pass 2/3 polish) ─────────────────────────────────
# One card look for every shop list (weapons / bundles / upgrades / chests):
# consistent bg, rounded corners, left accent stripe, padding + a hover lift.
const _CARD_BG := Color(0.07, 0.10, 0.17, 0.92)
const _CARD_BG_HOVER := Color(0.12, 0.16, 0.25, 0.97)
const _CARD_ACCENT := Color(0.42, 0.62, 0.92, 0.55)


func _card_box(accent: Color, hover: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = _CARD_BG_HOVER if hover else _CARD_BG
	sb.set_border_width_all(1)
	sb.border_width_left = 3
	sb.border_color = accent.lightened(0.3) if hover else accent
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 9
	sb.content_margin_bottom = 9
	return sb


# Apply the unified card style + a hover highlight to a PanelContainer.
func _style_card(pc: PanelContainer, accent: Color = _CARD_ACCENT) -> void:
	pc.add_theme_stylebox_override(&"panel", _card_box(accent, false))
	pc.mouse_filter = Control.MOUSE_FILTER_PASS   # still highlights, still passes clicks
	pc.mouse_entered.connect(func(): pc.add_theme_stylebox_override(&"panel", _card_box(accent, true)))
	pc.mouse_exited.connect(func(): pc.add_theme_stylebox_override(&"panel", _card_box(accent, false)))


func _btn_box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(1)
	sb.border_color = border
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	return sb


# Primary BUY action: green with hover/pressed feedback + a muted disabled state
# (so buttons that toggle, like "开启" when you have 0 chests, look right too).
func _style_buy_button(btn: Button) -> void:
	btn.add_theme_stylebox_override(&"normal", _btn_box(Color(0.15, 0.40, 0.23, 1), Color(0.4, 0.9, 0.5, 0.7)))
	btn.add_theme_stylebox_override(&"hover", _btn_box(Color(0.22, 0.56, 0.31, 1), Color(0.65, 1.0, 0.75, 0.95)))
	btn.add_theme_stylebox_override(&"pressed", _btn_box(Color(0.11, 0.30, 0.17, 1), Color(0.4, 0.9, 0.5, 0.9)))
	btn.add_theme_stylebox_override(&"disabled", _btn_box(Color(0.10, 0.12, 0.16, 0.8), Color(0.32, 0.38, 0.48, 0.4)))
	btn.add_theme_color_override(&"font_color", Color(0.88, 1.0, 0.92))
	btn.add_theme_color_override(&"font_hover_color", Color(1, 1, 1))
	btn.add_theme_color_override(&"font_disabled_color", Color(0.55, 0.62, 0.72))


# Muted disabled state (OWNED / locked).
func _style_muted_button(btn: Button) -> void:
	btn.add_theme_stylebox_override(&"disabled", _btn_box(Color(0.10, 0.12, 0.16, 0.8), Color(0.32, 0.38, 0.48, 0.4)))
	btn.add_theme_color_override(&"font_color_disabled", Color(0.55, 0.62, 0.72))


# Rounded "pill" background for the header currency labels.
func _pill_box(tint: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(tint.r, tint.g, tint.b, 0.14)
	sb.set_border_width_all(1)
	sb.border_color = Color(tint.r, tint.g, tint.b, 0.55)
	sb.set_corner_radius_all(13)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	return sb


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
	bundles.sort_custom(func(a, b): return a.discounted_price() < b.discounted_price())
	for b in bundles:
		bundles_list.add_child(_make_bundle_card(b))


func _make_bundle_card(b: Resource) -> PanelContainer:
	var s: Node = get_node(^"/root/Settings")
	var pc := PanelContainer.new()
	var accent: Color = b.theme_color if "theme_color" in b else _CARD_ACCENT
	_style_card(pc, accent)
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
	price_lbl.text = "折后 $%d (原价 $%d)" % [b.discounted_price(), b.full_price()]
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
		_style_muted_button(buy_btn)
	else:
		buy_btn.text = "BUY · $%d" % b.discounted_price()
		buy_btn.pressed.connect(_on_buy_bundle.bind(b))
		_style_buy_button(buy_btn)
	buy_row.add_child(buy_btn)
	return pc


func _on_buy_bundle(b: Resource) -> void:
	# Bundles have no dedicated server RPC yet — in online mode the trust
	# boundary doesn't allow client-driven spend_credits + mark_purchased.
	# Block with a clear message until a server-side bundle registry exists.
	if _is_online():
		_reveal("[color=#ff8888]Bundles not available online yet — only single-weapon purchases route through the server.[/color]")
		return
	var s: Node = get_node(^"/root/Settings")
	if not s.spend_credits(b.discounted_price()):
		_reveal("[color=#ff8888]Not enough credits — need $%d, have $%d.[/color]" % [b.discounted_price(), s.credits])
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
	_style_card(pc)
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
	if buy_btn.disabled:
		_style_muted_button(buy_btn)
	else:
		_style_buy_button(buy_btn)
	return pc


func _on_buy_weapon(w: Resource) -> void:
	var s: Node = get_node(^"/root/Settings")
	# Cheap affordability check for the offline path / instant feedback. The
	# server re-checks authoritatively, so a stale credit count here just
	# means a benign rejection round-trip — never a money leak.
	if not _is_online() and not s.can_afford_credits(w.price_credits):
		_reveal("[color=#ff8888]Not enough credits![/color]\n你需要 $ %d，但只有 $ %d。" % [w.price_credits, s.credits])
		return
	# request_purchase_weapon routes through the server when synced (ignoring
	# the client-sent price — server reads canonical price_credits) or falls
	# back to local spend/mark when offline.
	_pending_weapon_unlock_name = w.display_name
	_pending_weapon_unlock_desc = w.description
	if not s.request_purchase_weapon(String(w.id), w.price_credits):
		_pending_weapon_unlock_name = ""
		_pending_weapon_unlock_desc = ""
		_reveal("[color=#ff8888]Purchase failed.[/color]")
		return
	# Online: the reveal happens on server_action ack in _on_server_action.
	# Offline: request_purchase_weapon already did spend+mark synchronously
	# so we can reveal immediately.
	if not _is_online():
		_reveal("[color=#a8ff88]Unlocked %s![/color]\n[color=#cccccc]%s[/color]\n\n按 1-4 切换武器时可选。" % [w.display_name, w.description])
		_pending_weapon_unlock_name = ""
		_pending_weapon_unlock_desc = ""


# ── Chests tab ────────────────────────────────────────────────────────────
func _refresh_chests() -> void:
	var s: Node = get_node(^"/root/Settings")
	common_chest_count.text = "你有 %d 个" % s.common_chests
	rare_chest_count.text = "你有 %d 个" % s.rare_chests
	common_chest_btn.disabled = s.common_chests <= 0
	rare_chest_btn.disabled = s.rare_chests <= 0


func _on_buy_chest(kind: StringName) -> void:
	# No server RPC for stockpiling chests — the server only supports
	# buy+open atomically (open_chest spends a chest if available or pays
	# credits otherwise). In online mode, route the click straight to
	# open_chest; in offline mode keep the legacy add-to-inventory flow.
	if _is_online():
		_on_open_chest(kind)
		return
	var s: Node = get_node(^"/root/Settings")
	var price: int = COMMON_CHEST_PRICE if kind == &"common" else RARE_CHEST_PRICE
	if not s.spend_credits(price):
		_reveal("[color=#ff8888]Not enough credits[/color]")
		return
	s.add_chest(kind, 1)
	_reveal("[color=#88ccff]+1 %s chest[/color]" % ("common" if kind == &"common" else "rare"))


func _on_open_chest(kind: StringName) -> void:
	var s: Node = get_node(^"/root/Settings")
	# Online path: server rolls rewards authoritatively and pushes them via
	# server_reward → reward_received → _on_server_reward. Don't run the
	# local RNG/award code at all — that would double-credit and also let a
	# tampered client claim arbitrary rewards.
	if _is_online():
		# Cheap pre-check so the popup is informative; server re-checks.
		if s.common_chests == 0 and s.rare_chests == 0:
			var price: int = COMMON_CHEST_PRICE if kind == &"common" else RARE_CHEST_PRICE
			if s.credits < price:
				_reveal("[color=#ff8888]Not enough credits[/color]")
				return
		if not s.request_open_chest(String(kind)):
			_reveal("[color=#ff8888]Open chest unavailable.[/color]")
		return
	# Offline / legacy path: client-side RNG. Acceptable because there's no
	# server state to desync from.
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
	# Two-phase reveal — first show a "shaking chest" frame, then after a
	# short suspense window, swap to the actual reward. Pure cosmetic.
	# Server already chose + persisted; we're just timing the visual.
	var kind_label: String = "COMMON" if kind == &"common" else "RARE"
	var shake_color: String = "#88ccff" if kind == &"common" else "#ff88dd"
	var shake_frames: Array[String] = [
		"[center][color=%s]┌─■─┐\n│ ▒▒ │ ?\n└───┘[/color][/center]" % shake_color,
		"[center][color=%s] ┌─■─┐\n  │ ▓▓ │ ?\n └───┘[/color][/center]" % shake_color,
		"[center][color=%s]┌─■─┐\n│ ▒▒ │ ??\n└───┘[/color][/center]" % shake_color,
		"[center][color=%s] ┌─■─┐\n  │ ▓▓ │ ??\n └───┘[/color][/center]" % shake_color,
	]
	# Shake for ~0.8s.
	var t: Tween = create_tween()
	for i in 6:
		var frame: String = shake_frames[i % shake_frames.size()]
		t.tween_callback(func(): _reveal(frame)).set_delay(0.12)
	# Final reveal.
	var lines: Array[String] = []
	lines.append("[center][color=#ffd84a]✦ %s CHEST OPENED ✦[/color][/center]" % kind_label)
	lines.append("")
	lines.append("[color=#88ccff] +%d fragments[/color]" % frags)
	if creds > 0:
		lines.append("[color=#ffd84a]$ +%d credits[/color]" % creds)
	if weapon_name != "":
		lines.append("")
		lines.append("[color=#ff88dd]★ JACKPOT — unlocked %s! ★[/color]" % weapon_name)
	var final_text: String = "\n".join(lines)
	t.tween_callback(func(): _reveal(final_text)).set_delay(0.25)


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
	# Online: server authoritatively spins, picks reward, and pushes via
	# server_reward. _on_server_reward handles the UI. We still play the
	# dial animation locally — but the result label only fills in after the
	# reward arrives.
	if _is_online():
		wheel_spin_btn.disabled = true
		if not s.request_spin_wheel():
			wheel_spin_btn.disabled = false
			_reveal("[color=#ff8888]Spin unavailable.[/color]")
			return
		_start_wheel_animation(null)
		return
	# Offline: client-side RNG, mirrors the original local economy.
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
	# Real prize wheel: spin so the pointer LANDS on the picked segment.
	await _spin_wheel_to(WHEEL_OUTCOMES.find(picked))
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
	_style_card(pc)
	var row := HBoxContainer.new()
	pc.add_child(row)
	var name_label := Label.new()
	name_label.text = w.display_name
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	var max_lvl: int = NetProtocol.MAX_UPGRADE_LEVELS_PER_WEAPON
	for stat in [&"damage", &"mag", &"reload"]:
		var lvl: int = s.get_upgrade(String(w.id), stat)
		var btn := Button.new()
		var stat_label: String = "DMG" if stat == &"damage" else ("MAG" if stat == &"mag" else "RLD")
		btn.text = "%s lvl %d/%d" % [stat_label, lvl, max_lvl]
		if lvl < max_lvl:
			btn.text += "  +%d" % NetProtocol.UPGRADE_COST_PER_LEVEL
			# Local copies so each iteration's lambda captures its own values.
			var wid: String = String(w.id)
			var st: String = String(stat)
			var st_name: StringName = stat
			var target: int = lvl + 1
			btn.pressed.connect(func():
				# Online: route through the server RPC so the upgrade persists
				# (else the next server_profile sync overwrites the local change —
				# the P1 bug). request_apply_upgrade returns false when offline;
				# fall back to the local sandbox bump only then.
				if not s.request_apply_upgrade(wid, st, target):
					s.bump_upgrade(wid, st_name)
			)
		else:
			btn.disabled = true
			btn.text += "  MAX"
		btn.custom_minimum_size = Vector2(150, 28)
		row.add_child(btn)
	return pc


func _reveal(bbcode: String) -> void:
	reveal_text.text = bbcode
	reveal_dialog.popup_centered(Vector2i(520, 320))
	# Subtle content fade-in (Window itself can't scale-tween while embedded).
	reveal_text.modulate.a = 0.0
	create_tween().tween_property(reveal_text, "modulate:a", 1.0, 0.25)


# Server replied to a mutating shop op. Show the popup for purchase here so
# the success message only shows after the authoritative confirmation. The
# server_profile push that arrives alongside this ack drives the credit /
# inventory UI refresh via the existing credits_changed / purchased_changed
# signals.
func _on_server_action(action: String, ok: bool, reason: String) -> void:
	match action:
		"purchase":
			if ok and not _pending_weapon_unlock_name.is_empty():
				_reveal("[color=#a8ff88]Unlocked %s![/color]\n[color=#cccccc]%s[/color]\n\n按 1-4 切换武器时可选。" \
					% [_pending_weapon_unlock_name, _pending_weapon_unlock_desc])
			elif not ok:
				_reveal("[color=#ff8888]Purchase failed: %s[/color]" % reason)
			_pending_weapon_unlock_name = ""
			_pending_weapon_unlock_desc = ""
		"open_chest":
			if not ok:
				_reveal("[color=#ff8888]Chest open failed: %s[/color]" % reason)
		"spin":
			if not ok:
				wheel_spin_btn.disabled = false
				_reveal("[color=#ff8888]Spin failed: %s[/color]" % reason)


# Server-rolled rewards from open_chest / spin_wheel. The reward dict carries
# `credits` and/or `fragments` at minimum; the server has already credited
# them in the database, so we only need to render the reveal. Local economy
# state has already been refreshed via the parallel server_profile push.
func _on_server_reward(kind: String, reward: Dictionary) -> void:
	if kind == "common" or kind == "rare":
		var frags: int = int(reward.get("fragments", 0))
		var creds: int = int(reward.get("credits", 0))
		_animate_chest_reveal(StringName(kind), frags, creds, String(reward.get("weapon_name", "")))
	elif kind == "wheel":
		_show_wheel_reward(reward)


func _show_wheel_reward(reward: Dictionary) -> void:
	# Build a short label from whatever keys came back. Server reward dict
	# format mirrors profile_service.WHEEL_REWARDS (credits | fragments |
	# common_chests | rare_chests).
	var bits: Array[String] = []
	if reward.has("credits"):
		bits.append("$+%d credits" % int(reward.credits))
	if reward.has("fragments"):
		bits.append("+%d fragments" % int(reward.fragments))
	if reward.has("common_chests"):
		bits.append("+%d common chest" % int(reward.common_chests))
	if reward.has("rare_chests"):
		bits.append("+%d rare chest" % int(reward.rare_chests))
	var label_text: String = "\n".join(bits) if not bits.is_empty() else "(reward)"
	wheel_result.text = "[center][color=#ffd84a]! %s[/color][/center]" % label_text
	wheel_result.bbcode_enabled = true
	_refresh_wheel_hint()
	wheel_spin_btn.disabled = false


# Online: the server is authoritative for the reward, and its reward categories
# don't map 1:1 to the client wheel segments — so the spin is decorative. Land
# on a random segment; _show_wheel_reward fills in the real reward + re-enables
# the button when the server replies.
func _start_wheel_animation(_unused) -> void:
	await _spin_wheel_to(randi() % WHEEL_OUTCOMES.size())


# ── Prize-wheel widget (built procedurally over the scene's DialHolder) ─────
func _build_wheel() -> void:
	for c in wheel_holder.get_children():
		c.queue_free()
	wheel_holder.custom_minimum_size = Vector2(0, _WHEEL_SIZE.y + 8)
	var area := Control.new()
	area.custom_minimum_size = _WHEEL_SIZE
	area.size = _WHEEL_SIZE
	area.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wheel = _PRIZE_WHEEL.new()
	_wheel.size = _WHEEL_SIZE
	_wheel.pivot_offset = _WHEEL_SIZE * 0.5
	_wheel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(_wheel)
	_wheel.set_segments(_wheel_segments())
	var pointer := _PRIZE_WHEEL_POINTER.new()
	pointer.size = Vector2(_WHEEL_SIZE.x, 26)
	pointer.position = Vector2(0, -2)
	pointer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	area.add_child(pointer)
	wheel_holder.add_child(area)


func _wheel_segments() -> Array:
	var out: Array = []
	for o in WHEEL_OUTCOMES:
		out.append({"label": _wheel_short_label(String(o["name"])), "color": Color(o["color"])})
	return out


func _wheel_short_label(n: String) -> String:
	match n:
		"jackpot": return "JACKPOT"
		"big_bundle": return "BUNDLE"
		"small_rare": return "RARE"
		"big_frags": return "+100"
		"frags": return "+25"
		"credits": return "+$80"
	return "?"


# Spin so segment `index` lands under the top pointer, then highlight it.
# 4s quintic ease-out for a satisfying slow-down. Segment 0 sits at the top.
func _spin_wheel_to(index: int) -> void:
	if _wheel == null:
		return
	var n: int = maxi(1, WHEEL_OUTCOMES.size())
	var seg: float = TAU / float(n)
	var jitter: float = randf_range(-seg * 0.30, seg * 0.30)
	var target: float = TAU * 5.0 + _wheel.angle_for(index) + jitter
	_wheel.set_highlight(-1)
	_wheel.rotation = 0.0
	var t: Tween = create_tween()
	t.tween_property(_wheel, "rotation", target, 4.0) \
		.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	await t.finished
	_wheel.set_highlight(index)
