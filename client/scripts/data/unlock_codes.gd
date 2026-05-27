extends RefCounted
## Cheat / unlock code list — port of pvp-game's 18 admin codes + Admin Pass.
## Player enters one in the menu's hidden code input; server validates against
## this table and grants the listed reward. Codes are case-INsensitive on
## input; we lowercase before matching.
##
## Rewards format:
##   {"weapon": "ak20"}              — grant ownership of weapon "ak20"
##   {"all_weapons_minutes": 10}     — 10 min of every-weapon access
##   {"credits": 500}                — straight credit grant
##   {"fragments": 50}               — straight fragment grant
##   {"admin_pass": true}            — permanent admin badge (unlocks all
##                                     admin-only weapons + future cheats)
##
## Each code can only be redeemed ONCE per account; server tracks via the
## `accounts.redeemed_codes` column (TEXT JSON array).

const CODES: Dictionary = {
	# === 18 weapon-unlock codes (port from pvp-game) ===
	"kakaroto":       {"weapon": "railgun"},
	"goku":           {"weapon": "storm_cannon"},
	"vegeta":         {"weapon": "royal_minigun"},
	"trunks":         {"weapon": "barrett"},
	"piccolo":        {"weapon": "amr"},
	"frieza":         {"weapon": "shockwave_launcher"},
	"cell":           {"weapon": "gravity_launcher"},
	"buu":            {"weapon": "seismic_hammer"},
	"bulma":          {"weapon": "prism_launcher"},
	"chichi":         {"weapon": "freeze_gun"},
	"krillin":        {"weapon": "flechette"},
	"gohan":          {"weapon": "twin_ar"},
	"yamcha":         {"weapon": "magnet_rifle"},
	"tien":           {"weapon": "thermal_lmg"},
	"roshi":          {"weapon": "smart_smg"},
	"beerus":         {"weapon": "portal_launcher"},
	"whis":           {"weapon": "swarm_rifle"},
	"shenron":        {"weapon": "plasma_carbine"},
	# === Bonus codes ===
	"adminpass":      {"admin_pass": true},
	"longmao":        {"all_weapons_minutes": 10},
	"hangzhou2026":   {"credits": 500},
	"boobank":        {"fragments": 50},
}


## Returns the reward dict for `code` (lowercased before lookup), or null
## if no match. Static so server can call without instantiating.
static func reward_for(code: String) -> Variant:
	var key: String = code.strip_edges().to_lower()
	return CODES.get(key, null)
