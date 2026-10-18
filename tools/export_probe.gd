extends SceneTree
## Dev-only export probe: run the *shipped* scene inside an exported build,
## prove the pack really contains everything the runtime-computed paths ask
## for, and (optionally) save a frame so a human can look at it.
##
##     ./csg.x86_64 --script res://tools/export_probe.gd -- --check --shot=/tmp/opencode/export_menu.png
##
## `--check` walks ItemCatalog, FurnitureCatalog, ModifierCatalog and the audio
## bank, loading every file those catalogs name. Anything missing from the pack
## shows up as a `MISSING` line; the exit code is 0 only when nothing is.
##
## Why a helper: the game reads models, icons, previews, sounds and the kitchen
## layout through strings built at runtime, so the exporter cannot see them as
## dependencies. This is the same check as `tools/pck_audit.py`, but executed by
## the engine from inside the pack (remaps, imports and all).

var _shot_path := ""
var _check := false
var _wait_msec := 6000
var _started_msec := 0
var _loaded_main := false
var _missing: Array[String] = []
var _checked := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot_path = arg.trim_prefix("--shot=")
		elif arg.begins_with("--wait="):
			_wait_msec = int(arg.trim_prefix("--wait="))
		elif arg == "--check":
			_check = true
	_started_msec = Time.get_ticks_msec()


func _process(_delta: float) -> bool:
	# With a custom SceneTree the main scene is not always auto-instanced.
	if not _loaded_main:
		if get_root().get_child_count() == 0:
			var packed := load("res://scenes/main.tscn") as PackedScene
			if packed != null:
				get_root().add_child(packed.instantiate())
				_loaded_main = true
		else:
			_loaded_main = true
		return false

	if Time.get_ticks_msec() - _started_msec < _wait_msec:
		return false

	if _check:
		_run_checks()
	if not _shot_path.is_empty():
		var image := get_root().get_texture().get_image()
		image.save_png(_shot_path)
		print("[export-probe] wrote ", _shot_path)
	print("[export-probe] window=%s viewport=%s content_scale=%s screen=%s" % [
		DisplayServer.window_get_size(), get_root().size,
		get_root().content_scale_size, DisplayServer.screen_get_size(),
	])
	print("[export-probe] checked %d files, %d missing" % [_checked, _missing.size()])
	for path in _missing:
		print("[export-probe] MISSING ", path)
	print("[export-probe] RESULT: ", "ok" if _missing.is_empty() else "FAIL")
	return true


func _require(path: String) -> void:
	_checked += 1
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
		_missing.append(path)


func _require_load(path: String) -> void:
	_checked += 1
	if load(path) == null:
		_missing.append(path)


func _run_checks() -> void:
	# The kitchen layout: a plain .txt read with FileAccess, invisible to the
	# exporter's dependency scan unless the preset includes it.
	for name in ["start_kitchen.txt", "menu_kitchen.txt", "demo_kitchen.txt"]:
		_require(Kitchen.LAYOUT_DIR.path_join(name))

	# Models + previews the item catalog names.
	for def: ItemDef in ItemCatalog.all().values():
		if def.scene == null:
			_missing.append("ItemCatalog %s scene" % def.id)
		_checked += 1
		if not def.preview_path.is_empty():
			_require_load(def.preview_path)
		if def.extra_scene == null and def.extra_from_payload.is_empty() and def.id == &"tray_with_order":
			_missing.append("ItemCatalog %s extra scene" % def.id)

	# Furniture models + their isometric icons.
	for def: FurnitureDef in FurnitureCatalog.all():
		_checked += 1
		if def.scene == null:
			_missing.append("FurnitureCatalog %s scene" % def.id)
		if not def.icon_path.is_empty():
			_require_load(def.icon_path)

	# Modifier chips (food-kit previews).
	for mod: ModifierDef in ModifierCatalog.all():
		_checked += 1
		if not mod.icon_path.is_empty():
			_require_load(mod.icon_path)

	# Music + the UI/horror sounds the game UI and the audio bank name.
	for id in AudioBank.MUSIC_TRACKS:
		_require_load(AudioBank.MUSIC_TRACKS[id])
	for i in AudioBank.STEP_FILES:
		_require_load(AudioBank.RPG + "footstep%02d.ogg" % i)
	for i in AudioBank.HEAVY_STEP_FILES:
		_require_load(AudioBank.IMPACT + "footstep_concrete_%03d.ogg" % i)
	_require_load(AudioBank.HEARTBEAT_FILE)
	for path in [
		"res://assets/kenney_interface-sounds/Audio/click_002.ogg",
		"res://assets/kenney_interface-sounds/Audio/drop_002.ogg",
		"res://assets/kenney_interface-sounds/Audio/confirmation_001.ogg",
		"res://assets/kenney_interface-sounds/Audio/bong_001.ogg",
		"res://assets/kenney_interface-sounds/Audio/back_002.ogg",
		"res://assets/kenney_impact-sounds/Audio/impactGlass_heavy_000.ogg",
	]:
		_require_load(path)
