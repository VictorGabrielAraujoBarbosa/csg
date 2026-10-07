class_name PlaceController
extends Node3D
## Mouse-driven placement: a ghost follows the cursor on the grid, LMB places,
## RMB removes, R rotates, 1-9 picks an item.

signal selection_changed(text: String)

@export var kitchen: Kitchen
@export var camera: Camera3D
@export var catalog: Array[FurnitureDef] = []
## When false, the placer ignores input and hides its feedback (map edit mode).
var enabled := true

@export_group("Feedback colours")
@export var ghost_valid_color := Color(0.45, 1.0, 0.55, 0.45)
@export var ghost_invalid_color := Color(1.0, 0.35, 0.35, 0.45)
@export var highlight_valid_color := Color(0.3, 1.0, 0.4, 0.32)
@export var highlight_invalid_color := Color(1.0, 0.3, 0.3, 0.32)

var index := 0
var rot_steps := 0

var _ghost: FurnitureInstance
var _ghost_valid_mat: StandardMaterial3D
var _ghost_invalid_mat: StandardMaterial3D
var _highlight_root: Node3D
var _highlight_mesh: BoxMesh
var _highlight_valid_mat: StandardMaterial3D
var _highlight_invalid_mat: StandardMaterial3D
var _hover_cell := Vector2i.ZERO
var _has_hover := false
var _valid := false
var _last_cells: Array[Vector2i] = []
var _last_valid := false


func _ready() -> void:
	if kitchen == null:
		kitchen = get_node_or_null("../Kitchen") as Kitchen
	if camera == null:
		camera = get_node_or_null("../CameraRig/Camera3D") as Camera3D
	if catalog.is_empty():
		catalog = FurnitureCatalog.all()
	_ghost_valid_mat = _ghost_material(ghost_valid_color)
	_ghost_invalid_mat = _ghost_material(ghost_invalid_color)
	_highlight_mesh = BoxMesh.new()
	_highlight_mesh.size = Vector3(0.96, 0.015, 0.96)
	_highlight_valid_mat = _flat_material(highlight_valid_color)
	_highlight_invalid_mat = _flat_material(highlight_invalid_color)
	_highlight_root = Node3D.new()
	_highlight_root.name = "Highlight"
	add_child(_highlight_root)
	_rebuild_ghost()
	selection_changed.emit("")


func current_def() -> FurnitureDef:
	if catalog.is_empty():
		return null
	return catalog[posmod(index, catalog.size())]


func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled:
		_hide()


func _process(_delta: float) -> void:
	if not enabled or kitchen == null or camera == null or kitchen.data == null:
		return
	var mouse := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse)
	var dir := camera.project_ray_normal(mouse)
	if absf(dir.y) < 0.0001:
		_hide()
		return
	var t := -from.y / dir.y
	if t <= 0.0:
		_hide()
		return
	var cell := kitchen.world_to_cell(from + dir * t)
	_hover_cell = cell
	_has_hover = true
	_update_ghost()


func _unhandled_input(event: InputEvent) -> void:
	if not enabled or kitchen == null or kitchen.data == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		match key.physical_keycode:
			KEY_R:
				rot_steps = (rot_steps + 1) % 4
				_last_cells.clear()
			KEY_TAB:
				_select(index + 1)
			_:
				if key.physical_keycode >= KEY_1 and key.physical_keycode <= KEY_9:
					_select(key.physical_keycode - KEY_1)
	elif event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_try_place()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if kitchen.remove_furniture_at(_hover_cell):
				_last_cells.clear()


func _select(new_index: int) -> void:
	if catalog.is_empty():
		return
	index = posmod(new_index, catalog.size())
	rot_steps = 0
	_last_cells.clear()
	_rebuild_ghost()
	var def := current_def()
	selection_changed.emit("%s ($%d)" % [def.display_name, def.cost] if def != null else "")


func _try_place() -> void:
	if not _has_hover or not _valid:
		return
	var def := current_def()
	if def == null:
		return
	if kitchen.place_furniture(def, _hover_cell, rot_steps) != null:
		_last_cells.clear()


func _rebuild_ghost() -> void:
	if is_instance_valid(_ghost):
		remove_child(_ghost)
		_ghost.free()
	_ghost = null
	var def := current_def()
	if def == null:
		return
	_ghost = FurnitureInstance.new()
	_ghost.setup(def, Vector2i.ZERO, 0)
	add_child(_ghost)


func _update_ghost() -> void:
	var def := current_def()
	if def == null:
		return
	if _ghost == null or _ghost.def != def:
		_rebuild_ghost()
	_valid = kitchen.can_place(def, _hover_cell, rot_steps)
	var off := def.cell_center_offset(rot_steps)
	_ghost.visible = true
	_ghost.position = kitchen.cell_to_world(_hover_cell) + Vector3(off.x, 0.0, off.y)
	_ghost.rotation_degrees = Vector3(0.0, rot_steps * 90.0 + def.yaw_offset_deg, 0.0)
	_ghost.set_material_override_all(_ghost_valid_mat if _valid else _ghost_invalid_mat)
	_update_highlights(def)


func _update_highlights(def: FurnitureDef) -> void:
	var cells := def.cells(_hover_cell, rot_steps)
	if cells == _last_cells and _valid == _last_valid:
		return
	_last_cells = cells
	_last_valid = _valid
	for child in _highlight_root.get_children():
		child.queue_free()
	var mat := _highlight_valid_mat if _valid else _highlight_invalid_mat
	for c in cells:
		var mi := MeshInstance3D.new()
		mi.mesh = _highlight_mesh
		mi.material_override = mat
		mi.position = kitchen.cell_to_world(c) + Vector3(0.0, 0.01, 0.0)
		_highlight_root.add_child(mi)


func _hide() -> void:
	_has_hover = false
	if is_instance_valid(_ghost):
		_ghost.visible = false
	_last_cells.clear()
	for child in _highlight_root.get_children():
		child.queue_free()


func _ghost_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _flat_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return mat
