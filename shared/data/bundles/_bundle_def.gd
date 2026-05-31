@tool
class_name BundleDef extends Resource

# Mirrors BUNDLES table in /Users/longmao/projects/pvp-game/server.js line 93-118.

@export var id: StringName = &""
@export var display_name: String = ""
@export var description: String = ""
@export var icon: Texture2D
# price_credits is IGNORED for display/purchase — bundle price is now computed
# as a discount off the items' combined price (see discounted_price). The old
# hand-set price_credits values were above full_price, so bundles cost MORE than
# buying the guns individually ("省 0$", actually a markup). Kept only so old
# .tres still load; deliberately unused.
@export var price_credits: int = 0
@export var items: Array[WeaponDef] = []
@export var theme_color: Color = Color(1, 1, 1)

# Bundle = this fraction of the combined single-buy price (20% off).
const DISCOUNT := 0.8


# Sum of items' individual prices (what buying them one-by-one would cost).
func full_price() -> int:
	var total := 0
	for w in items:
		if w != null:
			total += w.price_credits
	return total


# Actual bundle price: a discount off full_price, so a bundle is ALWAYS cheaper
# than buying its guns individually. Rounded to a whole credit.
func discounted_price() -> int:
	return int(round(float(full_price()) * DISCOUNT))


func savings() -> int:
	return full_price() - discounted_price()
