extends Node
## Autoload — resolves the default multiplayer server URL.
## Strategy (mirrors arena-shooter-3d/scripts/main_menu.gd):
##   1. In web exports, fetch `server.json` from the same origin via HTTPRequest.
##   2. Native: try a bundled fallback at `res://server.json`.
##   3. Final fallback: `ws://127.0.0.1:7777` (local dev).
##
## Result is cached + emitted via `resolved` signal so the menu can update
## its LineEdit placeholder without blocking startup.

signal resolved(url: String)

## Both DS and HOST use 7777 — only one runs at a time, no conflict to surface.
const DEFAULT_URL := "ws://127.0.0.1:7777"
const REMOTE_HINT_FILE := "res://server.json"   # optional, ship in export
const FETCH_TIMEOUT_SEC := 3.0
# Reach NetProtocol via preload (the script class) not the autoload global so
# is_dedicated_server_boot() resolves under smoke test --script loading.
const NetProtocol = preload("res://shared/scripts/network/net_protocol.gd")

var url: String = DEFAULT_URL


func _ready() -> void:
	# C7: server discovery is a client-only concern. On --server boot, don't
	# read res://server.json or fire HTTPRequest — nothing to discover.
	if NetProtocol.is_dedicated_server_boot():
		return
	# Local-dev guard: when running from the editor (F5 / Play), KEEP the
	# 127.0.0.1 default even if server.json is checked in. Without this,
	# pressing CREATE ROOM in the editor connects to the production DS at
	# game.boobank.com (which usually lags behind local code → RPC
	# checksum mismatch and infinite "Connected — 等房主点 START").
	#
	# Use OS.is_debug_build(): true for editor + F5'd runtime + exported
	# debug builds, false ONLY for exported release builds. (Tried
	# OS.has_feature("editor") first — that's true ONLY in the editor's
	# own binary, NOT in the game runtime F5 launches, so it failed to
	# catch the F5 case.) For exported release builds (production
	# deploys), server.json is still read normally.
	if OS.is_debug_build():
		print("[ServerDiscovery] debug build — using local default ", url)
		resolved.emit(url)
		return
	# Exported native builds + web: try the bundled file first.
	if FileAccess.file_exists(REMOTE_HINT_FILE):
		var f := FileAccess.open(REMOTE_HINT_FILE, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if typeof(parsed) == TYPE_DICTIONARY:
				var u: String = parsed.get("ws_url", "")
				if not u.is_empty():
					url = u
					resolved.emit(url)
					return
	# Web export: try fetching same-origin /server.json via HTTPRequest. Falls
	# back to default if anything fails. (Browsers gate this by CORS — only
	# works when the JSON sits next to the HTML.)
	if OS.has_feature("web"):
		var req := HTTPRequest.new()
		add_child(req)
		req.timeout = FETCH_TIMEOUT_SEC
		req.request_completed.connect(_on_remote_fetched.bind(req))
		req.request("server.json")
		return
	# Native fallback — just emit the default.
	resolved.emit(url)


func _on_remote_fetched(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, req: HTTPRequest) -> void:
	if code == 200:
		var text: String = body.get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			var u: String = parsed.get("ws_url", "")
			if not u.is_empty():
				url = u
	resolved.emit(url)
	req.queue_free()
