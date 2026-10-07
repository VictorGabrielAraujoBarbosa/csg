@tool
class_name Kitchen
extends Node3D
## Builds the kitchen visuals from a [KitchenLayout] and answers every grid
## question the rest of the game asks (walkable, placeable, paintable).
##
## It is also the single editing API: paint floors and walls, place, remove and
## tint furniture, and undo. Edits keep [member data] in sync and only rebuild
## the pieces around the change, so the exported text always matches what you
## see and painting stays snappy.

signal layout_rebuilt
signal layout_edited

const CELL_SIZE := 1.0
const UNDO_LIMIT := 300
const PIECE_DIR := "res://assets/kenney_building-kit/Models/GLB format/"
const PIECE_FILES := {
	"floor": "floor.glb",
	"wall": "wall.glb",
	"wall_half": "wall-half.glb",
	"wall_low": "wall-low.glb",
	"window": "wall-window-square.glb",
	"doorway": "wall-doorway-square.glb",
	"column": "column-thin.glb",
}
const NO_EDGE := Vector3i(-2147483647, 0, 0)

@export_file("*.txt") var layout_file: String = "":
	set(value):
		layout_file = value
		if is_inside_tree():
			rebuild()
## Optional alternative to [member layout_file] (used by the editor paint tool
## later). If set, it wins over the file.
@export var layout: KitchenLayout
@export var build_floor := true
@export var build_walls := true
@export var build_columns := true
@export var show_grid := true

@export_group("Floor look")
@export var floor_tint := Color.WHITE
@export var plating_tint := Color(0.72, 0.78, 0.92)
## Classic checkerboard skin over every floor tile (assets untouched). Applied
## on top of the tile style and any painted tint.
@export var checker_enabled := true
@export var checker_light := Color.WHITE
@export var checker_dark := Color(0.86, 0.89, 0.94)
@export_range(0.0, 1.0, 0.01) var checker_amount := 0.8

@export_group("Grid overlay")
@export var grid_color := Color(0.06, 0.07, 0.1, 0.3)
@export var grid_line_width := 0.035
@export var grid_height := 0.012

var data: KitchenLayout

var _generated: Node3D
var _grid: MeshInstance3D
var _furniture_root: Node3D
var _furniture_by_cell: Dictionary = {}
var _furniture: Array[FurnitureInstance] = []
var _piece_cache: Dictionary = {}
var _material_cache: Dictionary = {}

# Incremental build bookkeeping.
var _floor_nodes: Dictionary = {}    # Vector2i cell -> Node3D
var _wall_entries: Array = []        # {"nodes": Array[Node3D], "vertices": Array[Vector2i]}
var _column_nodes: Dictionary = {}   # Vector2i doubled vertex -> Node3D
var _undo_stack: Array = []


func _ready() -> void:
	rebuild()


func rebuild() -> void:
	_load_layout()
	if is_instance_valid(_generated):
		remove_child(_generated)
		_generated.free()
	_generated = null
	_grid = null
	_floor_nodes.clear()
	_wall_entries.clear()
	_column_nodes.clear()
	if data == null:
		return
	_generated = Node3D.new()
	_generated.name = "Generated"
	add_child(_generated)
	if build_floor:
		_build_floor()
	if build_walls:
		_build_walls()
	_build_grid()
	_build_furniture_from_data()
	layout_rebuilt.emit()


func _load_layout() -> void:
	if layout != null:
		data = layout
		return
	data = null
	if layout_file.is_empty():
		return
	var f := FileAccess.open(layout_file, FileAccess.READ)
	if f == null:
		push_warning("Kitchen: cannot open layout file '%s'" % layout_file)
		return
	data = KitchenLayout.from_text(f.get_as_text())


# ---------------------------------------------------------------------------
# Grid queries
# ---------------------------------------------------------------------------

func cell_to_world(cell: Vector2i) -> Vector3:
	return Vector3(cell.x * CELL_SIZE, 0.0, cell.y * CELL_SIZE)


func world_to_cell(pos: Vector3) -> Vector2i:
	return Vector2i(roundi(pos.x / CELL_SIZE), roundi(pos.z / CELL_SIZE))


func has_floor(cell: Vector2i) -> bool:
	return data != null and data.has_floor(cell)


## A cell a character can stand on: floor and no furniture.
func is_walkable(cell: Vector2i) -> bool:
	return has_floor(cell) and not _furniture_by_cell.has(cell)


func get_world_bounds() -> Rect2:
	if data == null or data.floors.is_empty():
		return Rect2()
	var b := data.floor_bounds()
	return Rect2(
		Vector2(b.position.x - 0.5, b.position.y - 0.5),
		Vector2(b.size.x, b.size.y)
	)


func set_grid_visible(visible_now: bool) -> void:
	show_grid = visible_now
	if is_instance_valid(_grid):
		_grid.visible = visible_now


func is_grid_visible() -> bool:
	return show_grid


# ---------------------------------------------------------------------------
# Furniture
# ---------------------------------------------------------------------------

func can_place(def: FurnitureDef, anchor: Vector2i, steps: int) -> bool:
	if data == null or def == null:
		return false
	var cells := def.cells(anchor, steps)
	var cell_set := {}
	for c in cells:
		if not data.has_floor(c):
			return false
		if _furniture_by_cell.has(c):
			return false
		cell_set[c] = true
	# No wall may run through the footprint.
	for c in cells:
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if cell_set.has(n) and not data.can_cross(c, n):
				return false
	return true


func place_furniture(def: FurnitureDef, anchor: Vector2i, steps: int, tints := {}, record := true) -> FurnitureInstance:
	if not can_place(def, anchor, steps):
		return null
	var inst := _place_furniture_raw(def, anchor, steps, tints)
	if record:
		data.furniture.append(furniture_entry(inst))
		push_undo({"type": "furniture_add", "entry": furniture_entry(inst)})
		layout_edited.emit()
	return inst


func remove_furniture_at(cell: Vector2i, record := true) -> bool:
	var inst: FurnitureInstance = _furniture_by_cell.get(cell)
	if inst == null:
		return false
	remove_furniture(inst, record)
	return true


func remove_furniture(inst: FurnitureInstance, record := true) -> void:
	if inst == null:
		return
	var entry := furniture_entry(inst)
	for c in inst.footprint_cells():
		_furniture_by_cell.erase(c)
	_furniture.erase(inst)
	inst.queue_free()
	_erase_furniture_entry(entry)
	if record:
		push_undo({"type": "furniture_remove", "entry": entry})
		layout_edited.emit()


func furniture_at(cell: Vector2i) -> FurnitureInstance:
	return _furniture_by_cell.get(cell)


## Paints one material group of a piece ("*" = the whole piece, or a material
## name like "wood"). White resets that group to the original look.
func tint_furniture(inst: FurnitureInstance, color: Color, material := "*", record := true) -> bool:
	if inst == null:
		return false
	var old := inst.tint_for(material)
	if old.is_equal_approx(color):
		return false
	inst.set_tint(material, color)
	_apply_furniture_tints(inst)
	_sync_furniture_entry(inst)
	if record:
		push_undo({"type": "furniture_tint", "entry": furniture_entry(inst), "material": material, "old": old})
		layout_edited.emit()
	return true


## All placed furniture (used by tag presets).
func get_furniture_instances() -> Array[FurnitureInstance]:
	return _furniture.duplicate()


## The serialisable record of a placed piece.
func furniture_entry(inst: FurnitureInstance) -> Dictionary:
	return {"id": inst.def.id, "cell": inst.anchor, "steps": inst.rot_steps, "tints": inst.tints.duplicate()}


func _place_furniture_raw(def: FurnitureDef, anchor: Vector2i, steps: int, tints: Dictionary) -> FurnitureInstance:
	_ensure_furniture_root()
	var inst := FurnitureInstance.new()
	inst.name = String(def.id)
	inst.setup(def, anchor, steps)
	_furniture_root.add_child(inst)
	var off := def.cell_center_offset(steps)
	inst.position = cell_to_world(anchor) + Vector3(off.x, 0.0, off.y)
	for c in inst.footprint_cells():
		_furniture_by_cell[c] = inst
	_furniture.append(inst)
	inst.tints = tints.duplicate()
	_apply_furniture_tints(inst)
	return inst


func _ensure_furniture_root() -> void:
	if is_instance_valid(_furniture_root):
		return
	_furniture_root = Node3D.new()
	_furniture_root.name = "Furniture"
	add_child(_furniture_root)


func _build_furniture_from_data() -> void:
	if data == null:
		return
	_ensure_furniture_root()
	for child in _furniture_root.get_children():
		child.free()
	_furniture_by_cell.clear()
	_furniture.clear()
	for entry in data.furniture:
		var def := FurnitureCatalog.find(entry.get("id", &""))
		if def == null:
			continue
		var cell: Vector2i = entry.get("cell", Vector2i.ZERO)
		var steps: int = entry.get("steps", 0)
		if not can_place(def, cell, steps):
			continue
		_place_furniture_raw(def, cell, steps, entry.get("tints", {}))


func _erase_furniture_entry(entry: Dictionary) -> void:
	for i in range(data.furniture.size() - 1, -1, -1):
		var e: Dictionary = data.furniture[i]
		if e.get("id") == entry.get("id") and e.get("cell") == entry.get("cell") and e.get("steps") == entry.get("steps"):
			data.furniture.remove_at(i)
			return


func _sync_furniture_entry(inst: FurnitureInstance) -> void:
	var entry := furniture_entry(inst)
	for i in range(data.furniture.size()):
		var e: Dictionary = data.furniture[i]
		if e.get("id") == entry.id and e.get("cell") == entry.cell and e.get("steps") == entry.steps:
			data.furniture[i] = entry
			return
	data.furniture.append(entry)


## Applies every tint of the piece, surface by surface, using the surface's
## material name (wood, metal, glass, ...). "*" recolours the whole piece.
func _apply_furniture_tints(inst: FurnitureInstance) -> void:
	for mi in inst.meshes():
		if mi.mesh == null:
			continue
		for surface in mi.mesh.get_surface_count():
			var src: Material = mi.mesh.surface_get_material(surface)
			if src == null:
				mi.set_surface_override_material(surface, null)
				continue
			var tint := inst.tint_for(src.resource_name)
			if tint.is_equal_approx(Color.WHITE):
				mi.set_surface_override_material(surface, null)
			else:
				mi.set_surface_override_material(surface, _tinted_material("mat:%d" % src.get_instance_id(), src, tint))


# ---------------------------------------------------------------------------
# Painting API
# ---------------------------------------------------------------------------

func paint_floor(cell: Vector2i, kind: int, record := true) -> bool:
	if data == null:
		return false
	if kind == KitchenLayout.Floor.VOID and _furniture_by_cell.has(cell):
		return false
	var old: int = data.get_floor(cell)
	if old == kind:
		return false
	var old_tint: Color = data.floor_tints.get(cell, Color.WHITE)
	if kind == KitchenLayout.Floor.VOID:
		data.floor_tints.erase(cell)
	_apply_floor(cell, kind)
	if record:
		push_undo({"type": "floor", "cell": cell, "old": old, "old_tint": old_tint})
		layout_edited.emit()
	return true


func paint_floor_tint(cell: Vector2i, color: Color, record := true) -> bool:
	if data == null or not data.has_floor(cell):
		return false
	var old: Color = data.floor_tints.get(cell, Color.WHITE)
	if old.is_equal_approx(color):
		return false
	if color.is_equal_approx(Color.WHITE):
		data.floor_tints.erase(cell)
	else:
		data.floor_tints[cell] = color
	_refresh_floor_cell(cell)
	if record:
		push_undo({"type": "floor_tint", "cell": cell, "old": old})
		layout_edited.emit()
	return true


func can_paint_wall(key: Vector3i, kind: int) -> bool:
	if data == null:
		return false
	if kind != KitchenLayout.Wall.OPEN:
		# A wall may not cut through one piece of furniture.
		var cells := KitchenLayout.edge_cells(key)
		var a: FurnitureInstance = _furniture_by_cell.get(cells[0])
		var b: FurnitureInstance = _furniture_by_cell.get(cells[1])
		if a != null and a == b:
			return false
	return true


func paint_wall(cell: Vector2i, dir: int, kind: int, record := true) -> bool:
	var key := KitchenLayout.edge_key(cell, dir)
	if not can_paint_wall(key, kind):
		return false
	var old: int = data.get_wall_key(key)
	if old == kind:
		return false
	var old_tint: Color = data.wall_tints.get(key, Color.WHITE)
	if kind == KitchenLayout.Wall.OPEN:
		data.wall_tints.erase(key)
	_apply_wall(cell, dir, kind)
	if record:
		push_undo({"type": "wall", "cell": cell, "dir": dir, "old": old, "old_tint": old_tint})
		layout_edited.emit()
	return true


## Paints a wall edge ("*"-less: walls are separate pieces per tint).
func paint_wall_tint(cell: Vector2i, dir: int, color: Color, record := true) -> bool:
	if data == null:
		return false
	var key := KitchenLayout.edge_key(cell, dir)
	if data.get_wall_key(key) == KitchenLayout.Wall.OPEN:
		return false
	var old: Color = data.wall_tints.get(key, Color.WHITE)
	if old.is_equal_approx(color):
		return false
	_apply_wall_tint(cell, dir, color)
	if record:
		push_undo({"type": "wall_tint", "cell": cell, "dir": dir, "old": old})
		layout_edited.emit()
	return true


func _apply_wall_tint(cell: Vector2i, dir: int, color: Color) -> void:
	var key := KitchenLayout.edge_key(cell, dir)
	if color.is_equal_approx(Color.WHITE):
		data.wall_tints.erase(key)
	else:
		data.wall_tints[key] = color
	_refresh_walls_around([key])


func undo() -> bool:
	if _undo_stack.is_empty():
		return false
	var entry: Dictionary = _undo_stack.pop_back()
	if not _undo_one(entry):
		return false
	layout_edited.emit()
	return true


func _undo_one(entry: Dictionary) -> bool:
	match entry.get("type", ""):
		"floor":
			_apply_floor(entry.cell, entry.old)
			if entry.get("old_tint", Color.WHITE) != Color.WHITE:
				paint_floor_tint(entry.cell, entry.old_tint, false)
		"floor_tint":
			paint_floor_tint(entry.cell, entry.old, false)
		"wall":
			_apply_wall(entry.cell, entry.dir, entry.old)
			if entry.get("old_tint", Color.WHITE) != Color.WHITE:
				_apply_wall_tint(entry.cell, entry.dir, entry.old_tint)
		"wall_tint":
			_apply_wall_tint(entry.cell, entry.dir, entry.old)
		"furniture_add":
			var inst := _find_entry_instance(entry.entry)
			if inst != null:
				remove_furniture(inst, false)
		"furniture_remove":
			var def := FurnitureCatalog.find(entry.entry.get("id", &""))
			if def != null:
				_place_furniture_raw(def, entry.entry.cell, entry.entry.steps, entry.entry.get("tints", {}))
				data.furniture.append(entry.entry)
		"furniture_tint":
			var inst2 := _find_entry_instance(entry.entry)
			if inst2 != null:
				inst2.set_tint(entry.get("material", "*"), entry.old)
				_apply_furniture_tints(inst2)
				_sync_furniture_entry(inst2)
		"batch":
			for action in entry.get("actions", []):
				_undo_one(action)
		_:
			return false
	return true


func _find_entry_instance(entry: Dictionary) -> FurnitureInstance:
	var inst: FurnitureInstance = _furniture_by_cell.get(entry.get("cell", Vector2i.ZERO))
	if inst != null and inst.def.id == entry.get("id"):
		return inst
	return null


func _apply_floor(cell: Vector2i, kind: int) -> void:
	data.set_floor(cell, kind)
	_refresh_floor_cell(cell)
	# Floor/void borders derive default walls, so refresh the edges around it.
	var edges: Array[Vector3i] = []
	for k in _cell_edges(cell):
		edges.append(k)
	_refresh_walls_around(edges)


func _apply_wall(cell: Vector2i, dir: int, kind: int) -> void:
	data.set_wall(cell, dir, kind)
	_refresh_walls_around([KitchenLayout.edge_key(cell, dir)])


func push_undo(entry: Dictionary) -> void:
	_undo_stack.append(entry)
	if _undo_stack.size() > UNDO_LIMIT:
		_undo_stack.pop_front()


# ---------------------------------------------------------------------------
# Building: floors
# ---------------------------------------------------------------------------

func _piece(piece: String) -> PackedScene:
	if not _piece_cache.has(piece):
		_piece_cache[piece] = load(PIECE_DIR + PIECE_FILES[piece]) as PackedScene
	return _piece_cache[piece]


func _spawn_piece(piece: String, pos: Vector3, yaw_deg: float, scale_mul: float = 1.0, scale_axis := Vector3.ONE) -> Node3D:
	var node := _piece(piece).instantiate() as Node3D
	node.position = pos
	node.rotation_degrees = Vector3(0.0, yaw_deg, 0.0)
	node.scale = Vector3.ONE * scale_mul * scale_axis
	_generated.add_child(node)
	return node


func _build_floor() -> void:
	for cell: Vector2i in data.floors:
		_floor_nodes[cell] = _spawn_floor_cell(cell)


func _spawn_floor_cell(cell: Vector2i) -> Node3D:
	# floor.glb is a 2x2 tile: scale 0.5, sit it so the floor top is at y = 0.
	var node := _spawn_piece("floor", Vector3(cell.x, -0.05, cell.y), 0.0, 0.5)
	_apply_tint(node, "floor", _floor_display_tint(cell))
	return node


func _refresh_floor_cell(cell: Vector2i) -> void:
	if _generated == null:
		return
	if _floor_nodes.has(cell):
		(_floor_nodes[cell] as Node3D).free()
		_floor_nodes.erase(cell)
	if build_floor and data.has_floor(cell):
		_floor_nodes[cell] = _spawn_floor_cell(cell)


## Style tint * painted tint * checker shade.
func _floor_display_tint(cell: Vector2i) -> Color:
	var tint := floor_tint
	if data.get_floor(cell) == KitchenLayout.Floor.PLATING:
		tint = tint * plating_tint
	var painted: Color = data.floor_tints.get(cell, Color.WHITE)
	tint = tint * painted
	if checker_enabled:
		var shade := checker_light if ((cell.x + cell.y) & 1) == 0 else checker_dark
		tint = tint * Color.WHITE.lerp(shade, checker_amount)
	return tint


# ---------------------------------------------------------------------------
# Building: walls
# ---------------------------------------------------------------------------

func _build_walls() -> void:
	var keys := _wall_keys()
	_build_wall_pieces(keys)
	var vertices: Array[Vector2i] = []
	var seen := {}
	for k in keys:
		for v in _edge_vertices(k):
			if not seen.has(v):
				seen[v] = true
				vertices.append(v)
	_build_columns_for(vertices)


func _wall_keys() -> Array[Vector3i]:
	var seen := {}
	var out: Array[Vector3i] = []
	for cell: Vector2i in data.floors:
		for k in _cell_edges(cell):
			if not seen.has(k):
				seen[k] = true
				out.append(k)
	out.sort_custom(_edge_less)
	return out


## The four edges around a cell, canonicalised so each edge exists only once.
static func _cell_edges(cell: Vector2i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	out.append(KitchenLayout.edge_key(cell, KitchenLayout.DIR_X))
	out.append(KitchenLayout.edge_key(cell, KitchenLayout.DIR_Z))
	out.append(KitchenLayout.edge_key(cell - Vector2i(1, 0), KitchenLayout.DIR_X))
	out.append(KitchenLayout.edge_key(cell - Vector2i(0, 1), KitchenLayout.DIR_Z))
	return out


## Vertices of a cell in doubled world coordinates (all odd values).
static func _cell_vertex_keys(cell: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	out.append(Vector2i(2 * cell.x - 1, 2 * cell.y - 1))
	out.append(Vector2i(2 * cell.x + 1, 2 * cell.y - 1))
	out.append(Vector2i(2 * cell.x - 1, 2 * cell.y + 1))
	out.append(Vector2i(2 * cell.x + 1, 2 * cell.y + 1))
	return out


## The four edges meeting at a vertex (doubled coordinates).
static func _edges_at_vertex(v: Vector2i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	var cx := (v.x - 1) / 2
	var cz := (v.y - 1) / 2
	out.append(Vector3i(cx, cz, KitchenLayout.DIR_X))
	out.append(Vector3i(cx, cz + 1, KitchenLayout.DIR_X))
	out.append(Vector3i(cx, cz, KitchenLayout.DIR_Z))
	out.append(Vector3i(cx + 1, cz, KitchenLayout.DIR_Z))
	return out


func _edge_vertices(k: Vector3i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if k.z == KitchenLayout.DIR_X:
		out.append(Vector2i(2 * k.x + 1, 2 * k.y - 1))
		out.append(Vector2i(2 * k.x + 1, 2 * k.y + 1))
	else:
		out.append(Vector2i(2 * k.x - 1, 2 * k.y + 1))
		out.append(Vector2i(2 * k.x + 1, 2 * k.y + 1))
	return out


func _edge_less(a: Vector3i, b: Vector3i) -> bool:
	if a.z != b.z:
		return a.z < b.z
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x


func _edge_center(k: Vector3i) -> Vector3:
	if k.z == KitchenLayout.DIR_X:
		return Vector3(k.x + 0.5, 0.0, k.y)
	return Vector3(k.x, 0.0, k.y + 0.5)


func _edge_yaw(k: Vector3i) -> float:
	return 0.0 if k.z == KitchenLayout.DIR_X else 90.0


func _build_wall_pieces(keys: Array[Vector3i]) -> void:
	var key_set := {}
	for k in keys:
		key_set[k] = true
	var used := {}
	for k in keys:
		if used.has(k):
			continue
		var kind: int = data.get_wall_key(k)
		if kind == KitchenLayout.Wall.OPEN:
			continue
		var tint: Color = data.wall_tints.get(k, Color.WHITE)
		used[k] = true
		var partner := _find_partner(k, kind, tint, key_set, used)
		if partner == NO_EDGE:
			var node := _place_wall(_edge_center(k), _edge_yaw(k), kind, 1, tint)
			_register_wall_entry([k], node)
		else:
			used[partner] = true
			var node := _place_wall((_edge_center(k) + _edge_center(partner)) * 0.5, _edge_yaw(k), kind, 2, tint)
			_register_wall_entry([k, partner], node)


## A neighbouring edge on the same line, kind *and* tint, so two 1 m edges
## become one 2 m piece and the kit's panel seams line up.
func _find_partner(k: Vector3i, kind: int, tint: Color, key_set: Dictionary, used: Dictionary) -> Vector3i:
	var offsets: Array[Vector3i] = []
	if k.z == KitchenLayout.DIR_X:
		offsets.append(Vector3i(1, 0, 0))
		offsets.append(Vector3i(-1, 0, 0))
	else:
		offsets.append(Vector3i(0, 1, 0))
		offsets.append(Vector3i(0, -1, 0))
	for off in offsets:
		var n := k + off
		if key_set.has(n) and not used.has(n) and data.get_wall_key(n) == kind \
				and (data.wall_tints.get(n, Color.WHITE) as Color).is_equal_approx(tint):
			return n
	return NO_EDGE


func _place_wall(pos: Vector3, yaw: float, kind: int, length_cells: int, tint := Color.WHITE) -> Node3D:
	var piece := "wall_half"
	var scale_axis := Vector3.ONE
	match kind:
		KitchenLayout.Wall.SOLID:
			piece = "wall" if length_cells == 2 else "wall_half"
		KitchenLayout.Wall.WINDOW:
			piece = "window"
		KitchenLayout.Wall.DOORWAY:
			piece = "doorway"
		KitchenLayout.Wall.LOW:
			piece = "wall_low"
	if length_cells == 1 and kind != KitchenLayout.Wall.SOLID:
		# The kit only has 2 m windows / doorways / low walls; squeeze if odd.
		scale_axis = Vector3(1.0, 1.0, 0.5)
	var node := _spawn_piece(piece, pos, yaw, 1.0, scale_axis)
	_apply_tint(node, piece, tint)
	return node


func _register_wall_entry(edges: Array, node: Node3D) -> void:
	var vertices: Array[Vector2i] = []
	for k: Vector3i in edges:
		for v in _edge_vertices(k):
			if not vertices.has(v):
				vertices.append(v)
	_wall_entries.append({"nodes": [node], "vertices": vertices})


func _build_columns_for(vertices: Array[Vector2i]) -> void:
	for v in vertices:
		if _column_nodes.has(v):
			continue
		var incident: Array[Vector3i] = []
		for k in _edges_at_vertex(v):
			if data.get_wall_key(k) != KitchenLayout.Wall.OPEN:
				incident.append(k)
		if incident.is_empty():
			continue
		if incident.size() == 2 and _is_straight_through(incident[0], incident[1]):
			continue
		var node := _spawn_piece("column", Vector3(v.x * 0.5, 0.0, v.y * 0.5), 0.0)
		_column_nodes[v] = node


func _is_straight_through(a: Vector3i, b: Vector3i) -> bool:
	if a.z != b.z:
		return false
	if a.z == KitchenLayout.DIR_X:
		return a.x == b.x and absi(a.y - b.y) == 1
	return a.y == b.y and absi(a.x - b.x) == 1


## Rebuilds the wall pieces and columns in a small region around the changed
## edges. The region is expanded so that pairing and corner columns always see
## their neighbours.
func _refresh_walls_around(keys: Array[Vector3i]) -> void:
	if _generated == null or not build_walls or data == null:
		return
	var rect := _region_for(keys)
	var vertex_set := {}
	for x in range(rect.position.x, rect.end.x):
		for z in range(rect.position.y, rect.end.y):
			for v in _cell_vertex_keys(Vector2i(x, z)):
				vertex_set[v] = true
	var edge_set := {}
	for v: Vector2i in vertex_set:
		for k in _edges_at_vertex(v):
			edge_set[k] = true
	_remove_wall_entries_touching(vertex_set)
	for v: Vector2i in vertex_set:
		if _column_nodes.has(v):
			(_column_nodes[v] as Node3D).free()
			_column_nodes.erase(v)
	var edges: Array[Vector3i] = []
	for k: Vector3i in edge_set:
		edges.append(k)
	edges.sort_custom(_edge_less)
	_build_wall_pieces(edges)
	var vertices: Array[Vector2i] = []
	for v: Vector2i in vertex_set:
		vertices.append(v)
	_build_columns_for(vertices)


func _region_for(keys: Array[Vector3i]) -> Rect2i:
	var min_cell := Vector2i(1 << 30, 1 << 30)
	var max_cell := Vector2i(-(1 << 30), -(1 << 30))
	for k in keys:
		for cell in KitchenLayout.edge_cells(k):
			min_cell.x = mini(min_cell.x, cell.x)
			min_cell.y = mini(min_cell.y, cell.y)
			max_cell.x = maxi(max_cell.x, cell.x)
			max_cell.y = maxi(max_cell.y, cell.y)
	return Rect2i(min_cell - Vector2i(2, 2), max_cell - min_cell + Vector2i(5, 5))


func _remove_wall_entries_touching(vertices: Dictionary) -> void:
	var keep: Array = []
	for entry: Dictionary in _wall_entries:
		var touches := false
		for v: Vector2i in entry["vertices"]:
			if vertices.has(v):
				touches = true
				break
		if touches:
			for node: Node3D in entry["nodes"]:
				node.free()
		else:
			keep.append(entry)
	_wall_entries = keep


# ---------------------------------------------------------------------------
# Building: grid overlay
# ---------------------------------------------------------------------------

func _build_grid() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seen := {}
	for cell: Vector2i in data.floors:
		for k in _cell_edges(cell):
			if seen.has(k):
				continue
			seen[k] = true
			if k.z == KitchenLayout.DIR_X:
				_add_quad(st, Vector3(k.x + 0.5, grid_height, k.y), Vector2(grid_line_width, 1.0))
			else:
				_add_quad(st, Vector3(k.x, grid_height, k.y + 0.5), Vector2(1.0, grid_line_width))
	st.index()
	var mesh := st.commit()
	if mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = grid_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(0, mat)
	_grid = MeshInstance3D.new()
	_grid.name = "Grid"
	_grid.mesh = mesh
	_grid.visible = show_grid
	_generated.add_child(_grid)


static func _add_quad(st: SurfaceTool, center: Vector3, size: Vector2) -> void:
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var a := center + Vector3(-hx, 0.0, -hz)
	var b := center + Vector3(hx, 0.0, -hz)
	var c := center + Vector3(hx, 0.0, hz)
	var d := center + Vector3(-hx, 0.0, hz)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(b)
	st.add_vertex(a)
	st.add_vertex(d)
	st.add_vertex(c)


# ---------------------------------------------------------------------------
# Materials and tints (shared, cached by colour)
# ---------------------------------------------------------------------------

func _apply_tint(node: Node, piece: String, tint: Color) -> void:
	if tint.is_equal_approx(Color.WHITE):
		return
	var mat := _piece_material(piece, tint)
	if mat == null:
		return
	for child in node.get_children():
		if child is MeshInstance3D:
			(child as MeshInstance3D).material_override = mat
		_apply_tint(child, piece, tint)


func _piece_material(piece: String, tint: Color) -> Material:
	return _tinted_material("piece:" + piece, _source_material(_piece(piece)), tint)


func _tinted_material(key: String, source: Material, tint: Color) -> Material:
	var cache_key := "%s|%s" % [key, tint.to_html()]
	if _material_cache.has(cache_key):
		return _material_cache[cache_key]
	if source == null or not (source is BaseMaterial3D):
		return null
	var mat := (source as BaseMaterial3D).duplicate() as BaseMaterial3D
	mat.albedo_color = mat.albedo_color * tint
	_material_cache[cache_key] = mat
	return mat


func _source_material(scene: PackedScene) -> Material:
	var node := scene.instantiate() as Node3D
	var mesh := _first_mesh(node)
	var mat: Material = null
	if mesh != null and mesh.mesh != null:
		mat = mesh.mesh.surface_get_material(0)
	node.free()
	return mat


func _first_mesh(node: Node) -> MeshInstance3D:
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			return n
		for c in n.get_children():
			stack.append(c)
	return null
