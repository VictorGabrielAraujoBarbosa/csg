class_name PlaceController
extends Node3D
## Mouse-driven placement: a ghost follows the cursor on the grid, LMB places,
## RMB removes, R rotates, 1-9 picks an item.

signal selection_changed(text: String)

## How quickly a dragged piece catches up with the mouse (higher = tighter).
const GRAB_INERTIA := 7.0
## How quickly the purchase ghost follows the mouse.
const GHOST_INERTIA := 11.0
## Lift applied while carrying a piece, so it hovers above the floor.
const GRAB_LIFT := 0.22

@export var kitchen: Kitchen
@export var camera: Camera3D
@export var service: Service
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
## Drag-and-drop state: a placed piece being rearranged.
var _grabbed: FurnitureInstance = null
var _grab_visual := Vector3.ZERO
## The ghost lags behind the mouse like a heavy object.
var _ghost_visual := Vector3.ZERO
var _ghost_visual_ready := false


func _ready() -> void:
	if kitchen == null:
		kitchen = get_node_or_null("../Kitchen") as Kitchen
	if camera == null:
		camera = get_node_or_null("../CameraRig/Camera3D") as Camera3D
	if service == null:
		service = get_node_or_null("../Service") as Service
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


## Selects a catalog entry by id (used by the build catalog UI).
func select_by_id(id: StringName) -> void:
	for i in catalog.size():
		if catalog[i].id == id:
			_select(i)
			return


func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled:
		_hide()


func _process(delta: float) -> void:
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
	_update_ghost(delta)
	_update_grab(delta)


## The purchase ghost follows the mouse with a little inertia.
func _update_ghost(delta: float) -> void:
	var def := current_def()
	if def == null:
		return
	if _ghost == null or _ghost.def != def:
		_rebuild_ghost()
	_valid = kitchen.can_place(def, _hover_cell, rot_steps)
	var off := def.cell_center_offset(rot_steps)
	var target := kitchen.cell_to_world(_hover_cell) + Vector3(off.x, 0.0, off.y)
	if not _ghost_visual_ready:
		_ghost_visual = target
		_ghost_visual_ready = true
	else:
		_ghost_visual = _ghost_visual.lerp(target, 1.0 - exp(-GHOST_INERTIA * delta))
	_ghost.visible = _grabbed == null
	_ghost.position = _ghost_visual
	_ghost.rotation_degrees = Vector3(0.0, rot_steps * 90.0 + def.yaw_offset_deg, 0.0)
	_ghost.set_material_override_all(_ghost_valid_mat if _valid else _ghost_invalid_mat)
	_update_highlights(def)


## The grabbed piece hovers and lags behind the mouse while being carried.
func _update_grab(delta: float) -> void:
	if _grabbed == null:
		return
	var def := _grabbed.def
	_valid = kitchen.can_place(def, _hover_cell, rot_steps)
	var off := def.cell_center_offset(rot_steps)
	var target := kitchen.cell_to_world(_hover_cell) + Vector3(off.x, 0.0, off.y)
	_grab_visual = _grab_visual.lerp(target, 1.0 - exp(-GRAB_INERTIA * delta))
	_grabbed.position = _grab_visual + Vector3(0.0, GRAB_LIFT, 0.0)
	_grabbed.rotation_degrees = Vector3(0.0, rot_steps * 90.0 + def.yaw_offset_deg, 0.0)
	_grabbed.set_material_override_all(_ghost_valid_mat if _valid else _ghost_invalid_mat)
	_update_highlights(def)


func _grab(inst: FurnitureInstance) -> void:
	_grabbed = inst
	rot_steps = inst.rot_steps
	_grab_visual = inst.position - Vector3(0.0, GRAB_LIFT, 0.0)
	kitchen.begin_grab(inst)
	inst.set_material_override_all(_ghost_invalid_mat)


func _drop_grab() -> void:
	if _grabbed == null:
		return
	if kitchen.move_furniture(_grabbed, _hover_cell, rot_steps):
		kitchen.refresh_furniture_tints(_grabbed)
		_grabbed = null
		_last_cells.clear()
	else:
		# Invalid spot: keep holding it (red) until the player finds room.
		pass


func _cancel_grab() -> void:
	if _grabbed == null:
		return
	kitchen.cancel_grab(_grabbed)
	kitchen.refresh_furniture_tints(_grabbed)
	_grabbed = null
	_last_cells.clear()


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
			if _grabbed != null:
				_cancel_grab()
			elif kitchen.remove_furniture_at(_hover_cell):
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
	if not _has_hover:
		return
	if _grabbed != null:
		_drop_grab()
		return
	if not _valid:
		# Clicking an occupied cell picks that piece up for rearranging.
		var existing := kitchen.furniture_at(_hover_cell)
		if existing != null:
			_grab(existing)
		return
	var def := current_def()
	if def == null:
		return
	if service != null and not service.orders.try_spend(def.cost):
		return
	if kitchen.place_furniture(def, _hover_cell, rot_steps) != null:
		_last_cells.clear()
	elif service != null:
		# Placing failed for a non-money reason: give the money back.
		service.orders.add_money(def.cost)


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
