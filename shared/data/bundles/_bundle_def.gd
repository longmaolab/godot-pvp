@tool
class_name BundleDef extends Resource

# Mirrors BUNDLES table in /Users/longmao/projects/pvp-game/server.js line 93-118.

@export var id: StringName = &""
@export var display_name: String = ""
@export var description: String = ""
@export var icon: Texture2D
@export var price_credits: int = 0
@export var items: Array[WeaponDef] = []
@export var theme_color: Color = Color(1, 1, 1)


# Sum of items' individual prices — used to display "save X credits" framing.
# Equivalent to the discount math the original client renders in shop.
func full_price() -> int:
	var total := 0
	for w in items:
		if w != null:
			total += w.price_credits
	return total


func savings() -> int:
	return maxi(0, full_price() - price_credits)
