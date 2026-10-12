extends Node3D
## Wires the demo kitchen together and shows the control hints.
## M switches between furniture placement and map painting.

@onready var kitchen: Kitchen = $World/Kitchen
@onready var camera_rig: CameraRig = $World/CameraRig
@onready var placer: PlaceController = $World/PlaceController
@onready var map_editor: MapPaintController = $World/MapPaintController
@onready var day: DayController = $World/DayController
@onready var hint: Label = $UI/DevHud/Hint


func _ready() -> void:
	if kitchen.data == null:
		kitchen.rebuild()
	var wb := kitchen.get_world_bounds()
	if wb.size != Vector2.ZERO:
		camera_rig.set_bounds(wb)
		camera_rig.focus_on(Vector3(wb.get_center().x, 0.0, wb.get_center().y))
	placer.selection_changed.connect(func(_text: String) -> void: _update_hint())
	map_editor.tool_changed.connect(func(_text: String) -> void: _update_hint())
	_update_hint()


func _update_hint() -> void:
	var lines: PackedStringArray = []
	if map_editor.active:
		lines.append("MAP EDIT  —  %s" % map_editor.tool_label())
		lines.append("1-9/0 tools | [ ] cycle | C colour | V paint target | LMB paint | RMB erase | Ctrl+Z undo | Shift+P presets | M furniture")
	else:
		var def := placer.current_def()
		var item := "(no furniture)"
		if def != null:
			var tags: PackedStringArray = []
			for tag in def.tags:
				tags.append(String(tag))
			item = "%s  $%d  %dx%d  [%s]" % [
				def.display_name, def.cost, def.resolved_footprint().x, def.resolved_footprint().y, ", ".join(tags)
			]
		lines.append("FURNITURE  —  %s" % item)
		lines.append("1-9 pick | Tab next | R rotate | LMB place | RMB remove | M map edit")
	lines.append("WASD pan | Q/E turn camera | wheel zoom | G grid | N day | F5 export layout text")
	hint.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var key := event as InputEventKey
	match key.physical_keycode:
		KEY_M:
			var map_mode := not map_editor.active
			map_editor.set_active(map_mode)
			placer.set_enabled(not map_mode)
			_update_hint()
		KEY_G:
			kitchen.set_grid_visible(not kitchen.is_grid_visible())
		KEY_F5:
			_export_layout()
		KEY_N:
			_advance_day()
		KEY_Z:
			if key.ctrl_pressed:
				kitchen.undo()


## Dev shortcut until the build/day UI exists: N starts the next day (or leaves
## the summary screen).
func _advance_day() -> void:
	match day.phase:
		DayController.Phase.BUILD:
			var reasons := day.can_start_day()
			if reasons.is_empty():
				day.start_day()
			else:
				for text in reasons:
					service_warning(text)
		DayController.Phase.SUMMARY:
			day.finish_day()


func service_warning(text: String) -> void:
	var service := get_node_or_null("World/Service") as Service
	if service != null:
		service.emit_warning(text)
	print("[day] ", text)


func _export_layout() -> void:
	if kitchen.data == null:
		return
	var text := kitchen.data.to_text()
	var path := "user://kitchen_export.txt"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Could not write layout export")
		return
	f.store_string(text)
	f.close()
	print("--- layout exported to %s ---" % ProjectSettings.globalize_path(path))
	print(text)
