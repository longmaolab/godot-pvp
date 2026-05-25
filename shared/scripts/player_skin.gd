extends Node
## Per-player skin + animation state, extracted from PlayerController to keep
## the controller under 1000 lines.
##
## Reference via `const PlayerSkinScript = preload(...)` from PlayerController
## (intentionally NOT class_name'd — see player_visuals.gd for the same
## headless-test reason).
##
## Owns the 18-letter Kenney skin table and the active AnimationPlayer for the
## currently equipped GLB. Lives as a child of PlayerController; the controller
## calls into it via apply_skin / play_anim / select_anim and exposes a thin
## `apply_skin(idx)` wrapper for back-compat with existing test callers
## (tests/hitbox_geometry_test.gd, tests/measure_hitbox.gd both do
## `.call("apply_skin", idx)` on the player).

const SKIN_LETTERS := "abcdefghijklmnopqr"   # 18 Kenney skins
# Per-skin model scale. Kenney rigs have wildly different native heights
# (head-attach Y from 1.18 → 1.86 GLB units between skins a..r); a single
# scale leaves either the tall ones poking miles above the HeadHitbox or the
# short ones with their head buried inside the BodyHitbox. Each entry =
# 1.65 / measured native head-origin Y, so every skin's neck lands at world
# Y≈1.65, head mesh center near sphere center Y=1.9. Measured via
# tests/measure_hitbox.gd; re-run if Kenney updates the GLBs.
const SKIN_SCALES: Array = [
	0.888, 0.898, 0.911, 0.926, 0.926, 0.943, 0.964, 0.989, 1.017,
	1.017, 1.050, 1.088, 1.132, 1.183, 1.183, 1.243, 1.313, 1.397,
]
const SKIN_PATH := "res://assets/models/characters/character-%s.glb"

const ANIM_IDLE := "idle"
const ANIM_WALK := "walk"
const ANIM_SPRINT := "sprint"
const ANIM_DIE := "die"
const _ANIM_LOOPED := ["idle", "walk", "sprint"]

var _current_skin: int = -1
var _anim_player: AnimationPlayer = null
var _current_anim: String = ""


## Equip the GLB at SKIN_PATH[idx]. Wipes any prior model under `holder`,
## hides the procedural body meshes under `visuals_root`, and starts the GLB's
## idle loop. Idempotent: same idx + AnimationPlayer already wired = no-op.
func apply_skin(idx: int, holder: Node3D, visuals_root: Node3D) -> void:
	idx = clampi(idx, 0, SKIN_LETTERS.length() - 1)
	if idx == _current_skin and _anim_player != null:
		return
	_current_skin = idx
	if holder == null:
		return
	for c in holder.get_children():
		c.queue_free()
	var letter: String = SKIN_LETTERS.substr(idx, 1)
	var path: String = SKIN_PATH % letter
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		push_warning("[player] missing skin: %s" % path)
		return
	var model: Node3D = scene.instantiate() as Node3D
	if model == null:
		return
	model.scale = Vector3.ONE * SKIN_SCALES[idx]
	holder.add_child(model)
	# Hide the procedural body — GLB replaces it.
	if visuals_root != null:
		for body_name in ["Torso", "ArmL", "ArmR", "LegL", "LegR"]:
			var n: Node = visuals_root.get_node_or_null(NodePath(body_name))
			if n is MeshInstance3D:
				(n as MeshInstance3D).visible = false
	# Wire up the GLB's baked AnimationPlayer.
	_anim_player = _find_animation_player(model)
	if _anim_player:
		for n in _anim_player.get_animation_list():
			if n in _ANIM_LOOPED:
				var anim: Animation = _anim_player.get_animation(n)
				if anim:
					anim.loop_mode = Animation.LOOP_LINEAR
		play_anim(ANIM_IDLE)


## Switch to `anim` if not already playing it. Blend 120ms for everything
## except the death pose (which snaps to avoid the corpse easing out of frame).
func play_anim(anim: String) -> void:
	if _anim_player == null or anim == _current_anim:
		return
	if not _anim_player.has_animation(anim):
		return
	_current_anim = anim
	var blend: float = 0.0 if anim == ANIM_DIE else 0.12
	_anim_player.play(anim, blend)


## Pick an animation given the player's current state. Pure — no side effects.
## Caller is expected to feed the result back into play_anim() each tick.
func select_anim(is_dead: bool, velocity: Vector3) -> String:
	if is_dead:
		return ANIM_DIE
	var horiz: float = Vector2(velocity.x, velocity.z).length()
	if horiz > 7.5:
		return ANIM_SPRINT
	if horiz > 0.4:
		return ANIM_WALK
	return ANIM_IDLE


## Recursive: depth-first find the first AnimationPlayer in `node`'s subtree.
## Kenney's GLB imports nest the AnimationPlayer at varying depths, so a
## NodePath-style lookup wouldn't be portable across skins.
static func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var found: AnimationPlayer = _find_animation_player(c)
		if found:
			return found
	return null
