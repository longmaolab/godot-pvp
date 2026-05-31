class_name UiStyle extends RefCounted
## Shared UI design tokens + styling helpers so shop / room browser / lobby /
## dialogs all share ONE cohesive look. All static — call via a preloaded const
##   const UiStyle = preload("res://client/scripts/ui/ui_style.gd")
## so it resolves in standalone --script loads (no class_name global needed).

const CARD_BG := Color(0.07, 0.10, 0.17, 0.92)
const CARD_BG_HOVER := Color(0.12, 0.16, 0.25, 0.97)
const CARD_ACCENT := Color(0.42, 0.62, 0.92, 0.55)

# Button variant palettes: [bg, border, bg_hover, border_hover, bg_pressed].
const _BTN_PALETTE := {
	"primary": [Color(0.15, 0.40, 0.23, 1), Color(0.40, 0.90, 0.50, 0.7), Color(0.22, 0.56, 0.31, 1), Color(0.65, 1.0, 0.75, 0.95), Color(0.11, 0.30, 0.17, 1)],
	"neutral": [Color(0.12, 0.18, 0.28, 1), Color(0.45, 0.65, 0.95, 0.6), Color(0.18, 0.26, 0.40, 1), Color(0.6, 0.8, 1.0, 0.9), Color(0.10, 0.14, 0.22, 1)],
	"danger":  [Color(0.34, 0.13, 0.16, 1), Color(0.95, 0.45, 0.45, 0.7), Color(0.48, 0.18, 0.20, 1), Color(1.0, 0.6, 0.6, 0.95), Color(0.26, 0.10, 0.12, 1)],
}


static func card_box(accent: Color, hover: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = CARD_BG_HOVER if hover else CARD_BG
	sb.set_border_width_all(1)
	sb.border_width_left = 3
	sb.border_color = accent.lightened(0.3) if hover else accent
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 9
	sb.content_margin_bottom = 9
	return sb


# Unified card look + hover highlight on a PanelContainer.
static func style_card(pc: PanelContainer, accent: Color = CARD_ACCENT) -> void:
	var normal := card_box(accent, false)
	var hover := card_box(accent, true)
	pc.add_theme_stylebox_override(&"panel", normal)
	pc.mouse_filter = Control.MOUSE_FILTER_PASS
	pc.mouse_entered.connect(func(): pc.add_theme_stylebox_override(&"panel", hover))
	pc.mouse_exited.connect(func(): pc.add_theme_stylebox_override(&"panel", normal))


static func _btn_box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_border_width_all(1)
	sb.border_color = border
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb


# variant: "primary" (green) / "neutral" (blue) / "danger" (red).
static func style_button(btn: Button, variant: String = "primary") -> void:
	var p: Array = _BTN_PALETTE.get(variant, _BTN_PALETTE["primary"])
	btn.add_theme_stylebox_override(&"normal", _btn_box(p[0], p[1]))
	btn.add_theme_stylebox_override(&"hover", _btn_box(p[2], p[3]))
	btn.add_theme_stylebox_override(&"pressed", _btn_box(p[4], p[3]))
	btn.add_theme_stylebox_override(&"disabled", _btn_box(Color(0.10, 0.12, 0.16, 0.8), Color(0.32, 0.38, 0.48, 0.4)))
	btn.add_theme_color_override(&"font_color", Color(0.92, 0.97, 1.0))
	btn.add_theme_color_override(&"font_hover_color", Color(1, 1, 1))
	btn.add_theme_color_override(&"font_disabled_color", Color(0.55, 0.62, 0.72))


static func pill_box(tint: Color) -> StyleBoxFlat:
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


# Taller, more readable ItemList rows (room/player lists were cramped).
static func style_list(list: ItemList, font_size: int = 18, v_sep: int = 12) -> void:
	list.add_theme_font_size_override(&"font_size", font_size)
	list.add_theme_constant_override(&"v_separation", v_sep)
