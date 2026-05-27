---
description: Run Chrome E2E smoke against the live game.boobank.com/godot-pvp site. ~5 min, catches web-export bugs that headless tests miss.
---

# Chrome E2E smoke playbook

You are running a 5-minute manual UI smoke against the live deployed game at
**https://game.boobank.com/godot-pvp/**. The goal is to catch bugs that the
27 headless integration tests can't see: web-export issues, UI/UX regressions,
button wiring breaks, asset-loading failures.

## Prerequisites

Use the Chrome MCP tools (`mcp__Claude_in_Chrome__*`). If they're deferred,
load them all with `ToolSearch query="chrome" max_results=30` first.

Before any browser action:
1. `mcp__Claude_in_Chrome__list_connected_browsers` — confirm a browser is paired
2. `mcp__Claude_in_Chrome__select_browser` with the first deviceId
3. `mcp__Claude_in_Chrome__tabs_context_mcp` with `createIfEmpty: true`

If no browser is connected, stop and ask the user to open Chrome with the
Claude MCP extension signed in.

## The 8 checks

Batch each step's clicks + screenshot + console-read into a single
`mcp__Claude_in_Chrome__browser_batch` call to minimize round-trips. All
coordinates below assume a viewport of ~1400x846 (default Chrome MCP
screenshot size).

### 1. Baseline page load

- `navigate` to `https://game.boobank.com/godot-pvp/`
- `wait` 10 s
- `screenshot`
- `read_console_messages` with `pattern: "error|fail|ERROR|exception"` — confirm
  the expected baseline:
  - 3 `godot-sqlite` GDExtension errors (known web-only bug, no wasm32 build)
  - **anything else is new** — report it

### 2. MAP dropdown (top-left card)

- Click `(363, 442)` to open the MAP dropdown
- Verify 5 maps listed: Blank, Battlefield, KOTH, Trenches, Skydock
- Pick any non-default (e.g. Trenches at `(180, 580)`)
- Confirm PLAY summary at top-right updates

### 3. MODE dropdown

- Click `(363, 660)` (right after MAP selection, MODE shifts up)
- Verify ≥14 modes listed
- Pick any (e.g. FFA — first to 5 at `(156, 605)`)

### 4. Skin selector

- Click skin `▶` arrow at `(630, 318)` twice
- Verify "Character N (14/18)" → "Character P (16/18)"

### 5. Scroll left card, test WEAPON CATALOG + SHOP

Scroll the canvas first (it traps wheel events):
```javascript
const c=document.querySelector('canvas');
const r=c.getBoundingClientRect();
for(let i=0;i<6;i++) c.dispatchEvent(new WheelEvent('wheel',{
  bubbles:true, cancelable:true, deltaY:250, deltaMode:0,
  clientX:r.left+200, clientY:r.top+r.height/2
}));
```

- Click WEAPON CATALOG `(363, 651)` — verify weapon cards render
  (this was the `.tres.remap` bug, fixed in commit `adbcfda`).
  If still EMPTY: catalog regression.
- Close dialog with `(1090, 89)`
- Click SHOP `(363, 720)`
- Verify 5 tabs (Weapons / Chests / Wheel / Upgrades / Bundles) all switchable
- **Critical Bundles check**: in Bundles tab, verify every card's
  `总价` ≤ `单买`. If a bundle is more expensive than buying individually
  (e.g. ★Pistol Pack showed `$700 vs $540`), that's the pricing bug.
- Click back `◀ 返回菜单` at `(76, 31)`

### 6. CREATE ROOM

- Scroll back to top of right card if needed
- Click CREATE ROOM `(1027, 430)`
- Wait 5 s
- Screenshot
- **PASS if**: page transitions to `room_lobby.tscn` (clean lobby UI with map preview, player list, START button if host)
- **FAIL if**: stays on a "Connected — 等房主点 START" panel for >5s — this is
  the CREATE-flow staging bug (UX text wrong + possibly server not replying)
- Cancel with `(1027, 285)` to return to menu

### 7. BROWSE ROOMS / JOIN BY ADDRESS

- Click BROWSE ROOMS `(1027, 516)`
- Wait 3 s
- Verify ROOM LIST view appears with "Server: ..." header and 4 buttons
  (刷新 / + CREATE / JOIN / ← BACK)
- Click `← BACK` at `(959, 699)` to return

### 8. PRACTICE (full game smoke)

- Click PRACTICE `(1027, 213)`
- Wait 5 s
- Screenshot
- Verify HUD elements:
  - HP bar (top-left)
  - Ammo counter "AK20 · AR  30/90" (bottom-right)
  - Crosshair (center)
  - Weapon model (foreground)
- `read_console_messages` — flag any NEW errors beyond the 3 sqlite ones

## Report format

Write findings to `.agent/test.md` under a new `## YYYY-MM-DD — Chrome daily
smoke` heading. For each check: ✅ pass, ⚠ regression (existing bug), ❌ new
bug. Cross-reference any new issue against the known-bug table in the latest
existing report to avoid double-counting.

## Known issues to skip-flag (not new)

If the smoke turns up any of these, mark them ⚠ and move on:
- `godot-sqlite` web wasm32 missing (3 console errors)
- WEAPON CATALOG empty (until commit `adbcfda` deploys)
- CREATE ROOM stuck in "等房主点 START"
- Bundle 总价 > 单买
- MAP/MODE reset after SHOP visit
- Top "90 武器 / 15 模式 / 5 地图" badges look clickable but aren't
- HOST LAN error message misleading on web
- Pointer-lock `WrongDocumentError` after MCP-driven click — testing artifact, ignore

Anything else = report as new finding.
