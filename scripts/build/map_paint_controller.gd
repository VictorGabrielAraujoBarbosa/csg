class_name MapPaintController
extends Node3D
## In-game map editor: paint floors, walls, windows, doorways and low walls
## directly onto the kitchen, and tint furniture or floor tiles.
##
## Toggle with M. LMB paints, RMB erases, 1-8 pick a tool, [ / ] cycle,
## C cycles the tint colour, Ctrl+Z undoes.

signal tool_changed(text: String)

enum Tool { FLOOR_TILE, FLOOR_PLATING, WALL, WINDOW, DOORWAY, LOW, ERASE, TINT, WALL_TINT, PRESET, PICKUP, DELIVERY }

const TOOL_COUNT := 12
const TOOL_LABELS := [
	"Floor: tile", "Floor: plating", "Wall", "Window", "Doorway",
	"Low wall", "Erase", "Paint material", "Paint wall", "Tag preset",
	"Order intake point", "Order delivery point",
]

const WALL_PIECES := {
	Tool.WALL: "wall_half",
	Tool.WINDOW: "window",
	Tool.DOORWAY: "doorway",
	Tool.LOW: "wall_low",
}

@export var kitchen: Kitchen
@export var camera: Camera3D
@export var active := false
## Colour applied by the tag preset tool / Shift+P, keyed by furniture tag.
@export var tag_presets: Dictionary = {
	&"cooking": Color(0.93, 0.55, 0.5),
	&"heat": Color(0.93, 0.45, 0.4),
	&"prep": Color(0.6, 0.85, 0.6),
	&"washing": Color(0.55, 0.75, 0.93),
	&"water": Color(0.5, 0.7, 0.9),
	&"storage": Color(0.93, 0.82, 0.55),
	&"cold": Color(0.6, 0.85, 0.9),
	&"serving": Color(0.95, 0.72, 0.5),
	&"dining": Color(0.78, 0.65, 0.9),
	&"comfort": Color(0.72, 0.68, 0.92),
	&"bin": Color(0.6, 0.62, 0.66),
	&"desk": Color(0.62, 0.7, 0.85),
	&"decor": Color(0.55, 0.88, 0.82),
}
@export var tint_palette: Array[Color] = [
	Color.WHITE,
	Color(0.95, 0.55, 0.5),
	Color(0.95, 0.75, 0.45),
	Color(0.95, 0.92, 0.6),
	Color(0.6, 0.85, 0.55),
	Color(0.55, 0.8, 0.85),
	Color(0.55, 0.65, 0.9),
	Color(0.75, 0.6, 0.85),
	Color(0.55, 0.55, 0.6),
]

@export_group("Feedback colours")
@export var ghost_valid_color := Color(0.45, 1.0, 0.55, 0.45)
@export var ghost_invalid_color := Color(1.0, 0.35, 0.35, 0.45)
@export var cell_highlight_color := Color(0.35, 0.75, 1.0, 0.35)
@export var edge_highlight_color := Color(1.0, 0.85, 0.3, 0.7)

var tool: int = Tool.FLOOR_TILE
var tint_index := 0
## Which material group the paint tool targets: "*" or a material name.
var tint_target := "*"

var _cell := Vector2i.ZERO
var _edge := Vector3i.ZERO
var _has_hover := false
var _painting := false
var _last_cell := Vector2i(1 << 30, 1 << 30)
var _last_edge := Kitchen.NO_EDGE

var _cell_box: MeshInstance3D
var _cell_box_mesh: BoxMesh
var _edge_box: MeshInstance3D
var _edge_box_mesh: BoxMesh
var _cell_mat: StandardMaterial3D
var _edge_mat: StandardMaterial3D
var _ghost: Node3D
var _ghost_meshes: Array[MeshInstance3D] = []
var _ghost_piece := ""
var _ghost_valid_mat: StandardMaterial3D
var _ghost_invalid_mat: StandardMaterial3D


func _ready() -> void:
	if kitchen == null:
		kitchen = get_node_or_null("../Kitchen") as Kitchen
	if camera == null:
		camera = get_node_or_null("../CameraRig/Camera3D") as Camera3D
	_cell_box_mesh = BoxMesh.new()
	_cell_box_mesh.size = Vector3(0.96, 0.02, 0.96)
	_cell_mat = _flat_material(cell_highlight_color)
	_cell_box = MeshInstance3D.new()
	_cell_box.name = "CellHighlight"
	_cell_box.mesh = _cell_box_mesh
	_cell_box.material_override = _cell_mat
	_cell_box.visible = false
	add_child(_cell_box)
	_edge_box_mesh = BoxMesh.new()
	_edge_box_mesh.size = Vector3(0.16, 0.02, 1.0)
	_edge_mat = _flat_material(edge_highlight_color)
	_edge_box = MeshInstance3D.new()
	_edge_box.name = "EdgeHighlight"
	_edge_box.mesh = _edge_box_mesh
	_edge_box.material_override = _edge_mat
	_edge_box.visible = false
	add_child(_edge_box)
	_ghost_valid_mat = _flat_material(ghost_valid_color)
	_ghost_invalid_mat = _flat_material(ghost_invalid_color)


func set_active(value: bool) -> void:
	active = value
	if not value:
		_painting = false
		_cell_box.visible = false
		_edge_box.visible = false
		_clear_ghost()
	tool_changed.emit(tool_label())


func tool_label() -> String:
	var label: String = TOOL_LABELS[tool]
	if tool == Tool.TINT:
		label += " [%s, %d/%d]" % [tint_target, tint_index + 1, tint_palette.size()]
	return label


func _process(_delta: float) -> void:
	if not active or kitchen == null or camera == null or kitchen.data == null:
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
	var hit := from + dir * t
	_cell = kitchen.world_to_cell(hit)
	_edge = _edge_from_hit(hit, _cell)
	_has_hover = true
	_update_feedback()
	if _painting:
		_apply_tool(false)


func _unhandled_input(event: InputEvent) -> void:
	if not active or kitchen == null or kitchen.data == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := event as InputEventKey
		match key.physical_keycode:
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
				set_tool(key.physical_keycode - KEY_1)
			KEY_0:
				set_tool(Tool.PRESET)
			KEY_BRACKETLEFT:
				set_tool(posmod(tool - 1, TOOL_COUNT))
			KEY_BRACKETRIGHT:
				set_tool(posmod(tool + 1, TOOL_COUNT))
			KEY_C:
				tint_index = (tint_index + 1) % tint_palette.size()
				tool_changed.emit(tool_label())
			KEY_V:
				_cycle_tint_target()
			KEY_Y:
				set_tool(Tool.PICKUP)
			KEY_U:
				set_tool(Tool.DELIVERY)
			KEY_P:
				if key.shift_pressed:
					_apply_presets_to_all()
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_painting = mb.pressed
			_last_cell = Vector2i(1 << 30, 1 << 30)
			_last_edge = Kitchen.NO_EDGE
			if mb.pressed:
				_apply_tool(false)
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			_erase_at_hover()


func set_tool(new_tool: int) -> void:
	tool = posmod(new_tool, TOOL_COUNT)
	_clear_ghost()
	tool_changed.emit(tool_label())


## Cycles what the paint tool recolours: whole piece, then each material group
## of the hovered piece (wood, metal, glass, ...).
func _cycle_tint_target() -> void:
	var options := PackedStringArray(["*"])
	var inst := kitchen.furniture_at(_cell) if kitchen != null else null
	if inst != null:
		options.append_array(inst.material_names())
	var index := options.find(tint_target)
	tint_target = options[(index + 1) % options.size()]
	tool_changed.emit(tool_label())


## Colour a tag preset maps to, or white if the piece's tags have no preset.
func preset_color(def: FurnitureDef) -> Color:
	if def == null:
		return Color.WHITE
	for tag in def.tags:
		if tag_presets.has(tag):
			return tag_presets[tag]
	return Color.WHITE


func _apply_presets_to_all() -> void:
	if kitchen == null:
		return
	var actions: Array = []
	for inst in kitchen.get_furniture_instances():
		var color := preset_color(inst.def)
		if color.is_equal_approx(Color.WHITE):
			continue
		var old := inst.tint_for("*")
		if old.is_equal_approx(color):
			continue
		kitchen.tint_furniture(inst, color, "*", false)
		actions.append({"type": "furniture_tint", "entry": kitchen.furniture_entry(inst), "material": "*", "old": old})
	if not actions.is_empty():
		kitchen.push_undo({"type": "batch", "actions": actions})
		tool_changed.emit(tool_label())


func current_tint() -> Color:
	if tint_palette.is_empty():
		return Color.WHITE
	return tint_palette[posmod(tint_index, tint_palette.size())]


## The wall edge closest to where the cursor hit the floor.
func _edge_from_hit(hit: Vector3, cell: Vector2i) -> Vector3i:
	var local := Vector2(hit.x - cell.x, hit.z - cell.y)
	if absf(local.x) > absf(local.y):
		var ec := cell if local.x > 0.0 else cell - Vector2i(1, 0)
		return KitchenLayout.edge_key(ec, KitchenLayout.DIR_X)
	var ez := cell if local.y > 0.0 else cell - Vector2i(0, 1)
	return KitchenLayout.edge_key(ez, KitchenLayout.DIR_Z)


func _update_feedback() -> void:
	var edge_tool := WALL_PIECES.has(tool) or tool == Tool.WALL_TINT or tool == Tool.ERASE
	var ghost_tool := WALL_PIECES.has(tool)
	_cell_box.visible = not edge_tool or tool == Tool.TINT
	_edge_box.visible = edge_tool
	if _cell_box.visible:
		_cell_box.position = kitchen.cell_to_world(_cell) + Vector3(0, 0.01, 0)
	if _edge_box.visible:
		var center := _edge_center(_edge)
		_edge_box.position = center + Vector3(0, 0.01, 0)
		_edge_box.rotation_degrees = Vector3(0, 0 if _edge.z == KitchenLayout.DIR_X else 90, 0)
	_update_ghost(ghost_tool)


func _update_ghost(wall_tool: bool) -> void:
	if not wall_tool:
		_clear_ghost()
		return
	var piece: String = WALL_PIECES[tool]
	if _ghost == null or _ghost_piece != piece:
		_clear_ghost()
		var scene := load(Kitchen.PIECE_DIR + Kitchen.PIECE_FILES[piece]) as PackedScene
		_ghost = scene.instantiate() as Node3D
		add_child(_ghost)
		_ghost_piece = piece
		_ghost_meshes.clear()
		_collect_meshes(_ghost, _ghost_meshes)
	var kind := _wall_kind_for_tool()
	var valid := kitchen.can_paint_wall(_edge, kind)
	_ghost.visible = true
	_ghost.position = _edge_center(_edge)
	_ghost.rotation_degrees = Vector3(0, 0 if _edge.z == KitchenLayout.DIR_X else 90, 0)
	_ghost.scale = Vector3.ONE
	var mat := _ghost_valid_mat if valid else _ghost_invalid_mat
	for mi in _ghost_meshes:
		mi.material_override = mat


func _clear_ghost() -> void:
	if is_instance_valid(_ghost):
		remove_child(_ghost)
		_ghost.free()
	_ghost = null
	_ghost_piece = ""
	_ghost_meshes.clear()


func _wall_kind_for_tool() -> int:
	match tool:
		Tool.WALL:
			return KitchenLayout.Wall.SOLID
		Tool.WINDOW:
			return KitchenLayout.Wall.WINDOW
		Tool.DOORWAY:
			return KitchenLayout.Wall.DOORWAY
		Tool.LOW:
			return KitchenLayout.Wall.LOW
	return KitchenLayout.Wall.OPEN


func _apply_tool(_from_drag: bool) -> void:
	if not _has_hover:
		return
	match tool:
		Tool.FLOOR_TILE:
			if _cell == _last_cell:
				return
			_last_cell = _cell
			kitchen.paint_floor(_cell, KitchenLayout.Floor.TILE)
		Tool.FLOOR_PLATING:
			if _cell == _last_cell:
				return
			_last_cell = _cell
			kitchen.paint_floor(_cell, KitchenLayout.Floor.PLATING)
		Tool.WALL, Tool.WINDOW, Tool.DOORWAY, Tool.LOW:
			if _edge == _last_edge:
				return
			_last_edge = _edge
			kitchen.paint_wall(Vector2i(_edge.x, _edge.y), _edge.z, _wall_kind_for_tool())
		Tool.WALL_TINT:
			if _edge == _last_edge:
				return
			_last_edge = _edge
			kitchen.paint_wall_tint(Vector2i(_edge.x, _edge.y), _edge.z, current_tint())
		Tool.ERASE:
			_erase_at_hover()
		Tool.TINT:
			if _cell == _last_cell:
				return
			_last_cell = _cell
			var inst := kitchen.furniture_at(_cell)
			if inst != null:
				kitchen.tint_furniture(inst, current_tint(), tint_target)
			else:
				kitchen.paint_floor_tint(_cell, current_tint())
		Tool.PRESET:
			if _cell == _last_cell:
				return
			_last_cell = _cell
			var inst2 := kitchen.furniture_at(_cell)
			if inst2 != null:
				var color := preset_color(inst2.def)
				if not color.is_equal_approx(Color.WHITE):
					kitchen.tint_furniture(inst2, color, "*")
		Tool.PICKUP:
			if _cell == _last_cell:
				return
			_last_cell = _cell
			kitchen.paint_point(_cell, KitchenLayout.PointKind.PICKUP)
		Tool.DELIVERY:
			if _cell == _last_cell:
				return
			_last_cell = _cell
			kitchen.paint_point(_cell, KitchenLayout.PointKind.DELIVERY)


func _erase_at_hover() -> void:
	if not _has_hover:
		return
	# Contextual: a wall on the hovered edge first, then furniture, then a
	# structural point, then the floor itself.
	if kitchen.data.get_wall_key(_edge) != KitchenLayout.Wall.OPEN:
		kitchen.paint_wall(Vector2i(_edge.x, _edge.y), _edge.z, KitchenLayout.Wall.OPEN)
		return
	if kitchen.furniture_at(_cell) != null:
		kitchen.remove_furniture_at(_cell)
		return
	if kitchen.is_point(_cell):
		kitchen.clear_point(_cell)
		return
	kitchen.paint_floor(_cell, KitchenLayout.Floor.VOID)


func _hide() -> void:
	_has_hover = false
	_cell_box.visible = false
	_edge_box.visible = false
	_clear_ghost()


func _edge_center(k: Vector3i) -> Vector3:
	if k.z == KitchenLayout.DIR_X:
		return Vector3(k.x + 0.5, 0.0, k.y)
	return Vector3(k.x, 0.0, k.y + 0.5)


static func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)


func _flat_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat
