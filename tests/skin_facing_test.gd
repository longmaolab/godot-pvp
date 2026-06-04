extends SceneTree
## Regression guard for the character-facing fix (2026-06-03).
##
## Kenney's character GLBs face +Z; a Godot node's forward is -Z. apply_skin()
## must spin the model 180° so the FACE aligns with the node's -Z forward —
## otherwise two players aiming at each other each see the other's BACK, and a
## moving character runs backwards (user-reported, reproduced from screenshots).
##
## Asserts: after apply_skin, the equipped model is rotated PI around Y, so its
## local +Z (where the face is) points along the holder's -Z.

const PlayerSkin = preload("res://shared/scripts/player_skin.gd")

var failures: Array = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var skin: Object = PlayerSkin.new()
	var holder := Node3D.new()
	var visuals := Node3D.new()
	root.add_child(visuals)
	visuals.add_child(holder)
	await physics_frame

	# Equip a couple of skins and confirm each one gets the 180° correction.
	for idx in [0, 7, 17]:
		skin._current_skin = -1   # force re-equip (apply_skin early-returns on same idx)
		skin.apply_skin(idx, holder, visuals)
		await physics_frame
		var model: Node3D = null
		for c in holder.get_children():
			if c is Node3D:
				model = c
				break
		if model == null:
			_fail("skin %d: no model instantiated under holder" % idx)
			continue
		# The model's local +Z (where the face is) must point along the holder's
		# -Z (forward) after the 180° spin. basis.z carries the model's scale, so
		# check the SIGN, not the magnitude: corrected → basis.z.z < 0, broken
		# (no spin) → basis.z.z > 0.
		var face_z: float = model.transform.basis.z.z
		if face_z >= 0.0:
			_fail("skin %d: model not 180°-corrected — face points +Z/backward (basis.z.z=%.3f, rotation.y=%.3f). Opponents would see this character's BACK." % [
				idx, face_z, model.rotation.y])
		else:
			print("  [ok] skin %d: face aligned to node -Z forward (basis.z.z=%.3f, rotation.y=%.3f)" % [idx, face_z, model.rotation.y])

	if failures.is_empty():
		print("  PASS — character models face their aim direction (180° GLB correction applied)")
		quit(0)
	else:
		for f in failures:
			print("  FAIL: %s" % f)
		quit(1)


func _fail(msg: String) -> void:
	failures.append(msg)
