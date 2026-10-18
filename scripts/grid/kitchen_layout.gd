class_name KitchenLayout
extends Resource
## Grid data for one kitchen map.
##
## Cells are [code]Vector2i(x, z)[/code] on a 1 m grid: cell (x, z) is centered at
## world position (x, 0, z). Walls live on the edges between cells:
## [code]DIR_X[/code] edges sit between (x, z) and (x+1, z) (the line x + 0.5),
## [code]DIR_Z[/code] edges sit between (x, z) and (x, z+1) (the line z + 0.5).
##
## Maps are stored as text (see [method to_text]) so they are easy to draw,
## diff, export and re-import.

enum Wall { OPEN = 0, SOLID, WINDOW, DOORWAY, LOW }
enum Floor { VOID = 0, TILE, PLATING }
enum PointKind { PICKUP = 0, DELIVERY = 1 }

const DIR_X := 0 ## Edge between (x, z) and (x + 1, z); its line runs along Z.
const DIR_Z := 1 ## Edge between (x, z) and (x, z + 1); its line runs along X.

const CELL_FLOOR := "."
const CELL_PLATING := ":"
const WALL_CHAR := {
	Wall.SOLID: "-",
	Wall.WINDOW: "w",
	Wall.DOORWAY: "d",
	Wall.LOW: "l",
}
const CHAR_WALL := {
	"-": Wall.SOLID,
	"|": Wall.SOLID,
	"w": Wall.WINDOW,
	"d": Wall.DOORWAY,
	"l": Wall.LOW,
	" ": Wall.OPEN,
}

## Vector2i cell -> [enum Floor]. Absent = VOID.
@export var floors: Dictionary = {}
## Vector3i(x, z, dir) edge -> [enum Wall]. Absent = derived (solid at the map
## border, open between two floor cells).
@export var walls: Dictionary = {}
## Optional per-cell floor tints: Vector2i -> Color (multiplied over the tile).
@export var floor_tints: Dictionary = {}
## Optional per-edge wall tints: Vector3i(x, z, dir) -> Color.
@export var wall_tints: Dictionary = {}
## Structural points: Vector2i cell -> [enum PointKind] (order intake / delivery).
@export var points: Dictionary = {}
## Placed furniture: each entry is {id: StringName, cell: Vector2i, steps: int,
## tints: Dictionary}. "tints" maps material name -> Color, with "*" meaning the
## whole piece. Part of the layout so a map export includes everything on it.
@export var furniture: Array = []


func has_floor(cell: Vector2i) -> bool:
	return floors.has(cell)


func get_floor(cell: Vector2i) -> int:
	return floors.get(cell, Floor.VOID)


func set_floor(cell: Vector2i, kind: int) -> void:
	if kind == Floor.VOID:
		floors.erase(cell)
	else:
		floors[cell] = kind


static func edge_key(cell: Vector2i, dir: int) -> Vector3i:
	return Vector3i(cell.x, cell.y, dir)


## Cell offset of an edge direction: the other cell sharing the edge.
static func dir_offset(dir: int) -> Vector2i:
	return Vector2i(1, 0) if dir == DIR_X else Vector2i(0, 1)


static func edge_cells(key: Vector3i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if key.z == DIR_X:
		out.append(Vector2i(key.x, key.y))
		out.append(Vector2i(key.x + 1, key.y))
	else:
		out.append(Vector2i(key.x, key.y))
		out.append(Vector2i(key.x, key.y + 1))
	return out


## Effective wall kind of an edge: the explicit value if set, otherwise solid
## wherever a floor cell meets void, open everywhere else.
func get_wall_key(key: Vector3i) -> int:
	if walls.has(key):
		return walls[key]
	var cells := edge_cells(key)
	return Wall.SOLID if has_floor(cells[0]) != has_floor(cells[1]) else Wall.OPEN


func get_wall(cell: Vector2i, dir: int) -> int:
	return get_wall_key(edge_key(cell, dir))


func set_wall(cell: Vector2i, dir: int, kind: int) -> void:
	var key := edge_key(cell, dir)
	# Keep the dict sparse: only store what differs from the derived default.
	var other := cell + dir_offset(dir)
	var derived := Wall.SOLID if has_floor(cell) != has_floor(other) else Wall.OPEN
	if kind == derived:
		walls.erase(key)
	else:
		walls[key] = kind


## Effective wall kind between two orthogonally adjacent cells.
func wall_between(a: Vector2i, b: Vector2i) -> int:
	if absi(a.x - b.x) + absi(a.y - b.y) != 1:
		return Wall.OPEN
	if b.x == a.x + 1:
		return get_wall_key(edge_key(a, DIR_X))
	if a.x == b.x + 1:
		return get_wall_key(edge_key(b, DIR_X))
	if b.y == a.y + 1:
		return get_wall_key(edge_key(a, DIR_Z))
	return get_wall_key(edge_key(b, DIR_Z))


## True if a character / worker can move between two adjacent cells.
func can_cross(a: Vector2i, b: Vector2i) -> bool:
	if not has_floor(a) or not has_floor(b):
		return false
	var kind := wall_between(a, b)
	return kind == Wall.OPEN or kind == Wall.DOORWAY


## Bounding box of all floor cells, in cell coordinates.
func floor_bounds() -> Rect2i:
	if floors.is_empty():
		return Rect2i()
	var min_cell := Vector2i(1 << 30, 1 << 30)
	var max_cell := Vector2i(-(1 << 30), -(1 << 30))
	for cell: Vector2i in floors:
		min_cell.x = mini(min_cell.x, cell.x)
		min_cell.y = mini(min_cell.y, cell.y)
		max_cell.x = maxi(max_cell.x, cell.x)
		max_cell.y = maxi(max_cell.y, cell.y)
	return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)


# ---------------------------------------------------------------------------
# Text format
#
# A map is drawn as a little floor plan where rooms are dots and walls are the
# lines between them:
#
#     +-+-w-+
#     |. . .|
#     + +-d +
#     |. . :|
#     +-----+
#
# cells:   '.'  floor (tile)      ':'  floor (plating)     ' '  void
# edges:   '-' / '|' solid wall   'w' window   'd' doorway   'l' low wall
# vertices: '+' is only cosmetic (readability), the parser ignores it.
# ---------------------------------------------------------------------------

func to_text() -> String:
	var parts: PackedStringArray = []
	var b := floor_bounds()
	if b.size != Vector2i.ZERO:
		b = b.grow(1)
		for r in range(2 * b.size.y + 1):
			var row := ""
			for c in range(2 * b.size.x + 1):
				if r % 2 == 0 and c % 2 == 0:
					row += _vertex_char(b.position.x + c / 2, b.position.y + r / 2)
				elif r % 2 == 0:
					row += _edge_char(Vector2i(b.position.x + (c - 1) / 2, b.position.y + (r - 2) / 2), DIR_Z)
				elif c % 2 == 0:
					row += _edge_char(Vector2i(b.position.x + (c - 2) / 2, b.position.y + (r - 1) / 2), DIR_X)
				else:
					row += _cell_char(Vector2i(b.position.x + (c - 1) / 2, b.position.y + (r - 1) / 2))
			parts.append(row)
	if not floor_tints.is_empty():
		parts.append("[colors]")
		for cell: Vector2i in floor_tints:
			parts.append("%d %d %s" % [cell.x, cell.y, floor_tints[cell].to_html(false)])
	if not wall_tints.is_empty():
		parts.append("[wallcolors]")
		for key: Vector3i in wall_tints:
			parts.append("%d %d %d %s" % [key.x, key.y, key.z, wall_tints[key].to_html(false)])
	if not points.is_empty():
		parts.append("[points]")
		for cell: Vector2i in points:
			var kind: int = points[cell]
			parts.append("%s %d %d" % ["pickup" if kind == PointKind.PICKUP else "delivery", cell.x, cell.y])
	if not furniture.is_empty():
		parts.append("[furniture]")
		for entry in furniture:
			var line := "%s %d %d %d" % [entry.id, entry.cell.x, entry.cell.y, entry.steps]
			var tints: Dictionary = entry.get("tints", {})
			for name: String in tints:
				line += " %s=%s" % [name, (tints[name] as Color).to_html(false)]
			parts.append(line)
	return "\n".join(parts) + "\n"


## A blank rectangular room: every cell floor, walls derived, nothing placed.
## Used by the level designer's "new map".
static func blank(size: Vector2i, floor_kind := Floor.TILE) -> KitchenLayout:
	var layout := KitchenLayout.new()
	var w := maxi(size.x, 1)
	var h := maxi(size.y, 1)
	for x in w:
		for z in h:
			layout.floors[Vector2i(x, z)] = floor_kind
	return layout


static func from_text(text: String) -> KitchenLayout:
	var layout := KitchenLayout.new()
	var lines: PackedStringArray = []
	for line in text.split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		if line.is_empty() and lines.is_empty():
			continue
		lines.append(line)
	while not lines.is_empty() and lines[lines.size() - 1].strip_edges().is_empty():
		lines.remove_at(lines.size() - 1)

	var map_lines: PackedStringArray = []
	var sections := {}
	var section := ""
	for line in lines:
		var trimmed := line.strip_edges()
		if trimmed.begins_with("[") and trimmed.ends_with("]"):
			section = trimmed.substr(1, trimmed.length() - 2).to_lower()
			sections[section] = []
			continue
		if section.is_empty():
			map_lines.append(line)
		else:
			(sections[section] as Array).append(line)

	if map_lines.size() >= 3:
		_parse_map(layout, map_lines)
	_parse_colors(layout, sections.get("colors", []))
	_parse_wallcolors(layout, sections.get("wallcolors", []))
	_parse_points(layout, sections.get("points", []))
	_parse_furniture(layout, sections.get("furniture", []))
	return layout


static func _parse_map(layout: KitchenLayout, lines: PackedStringArray) -> void:
	var width := 0
	for line in lines:
		width = maxi(width, line.length())
	if width < 3:
		return
	var cells_w := (width - 1) / 2
	var cells_h := (lines.size() - 1) / 2

	for z in range(cells_h):
		for x in range(cells_w):
			var ch := _line_char(lines[2 * z + 1], 2 * x + 1)
			if ch == CELL_FLOOR:
				layout.set_floor(Vector2i(x, z), Floor.TILE)
			elif ch == CELL_PLATING:
				layout.set_floor(Vector2i(x, z), Floor.PLATING)

	for z in range(cells_h):
		for x in range(cells_w):
			var cell := Vector2i(x, z)
			_store_edge(layout, cell, DIR_X, CHAR_WALL.get(_line_char(lines[2 * z + 1], 2 * x + 2), -1))
			_store_edge(layout, cell, DIR_Z, CHAR_WALL.get(_line_char(lines[2 * z + 2], 2 * x + 1), -1))


static func _parse_colors(layout: KitchenLayout, lines: Array) -> void:
	for line in lines:
		var parts := String(line).strip_edges().split(" ", false)
		if parts.size() >= 3:
			var cell := Vector2i(int(parts[0]), int(parts[1]))
			layout.floor_tints[cell] = Color.from_string(parts[2], Color.WHITE)


static func _parse_wallcolors(layout: KitchenLayout, lines: Array) -> void:
	for line in lines:
		var parts := String(line).strip_edges().split(" ", false)
		if parts.size() >= 4:
			var key := Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
			layout.wall_tints[key] = Color.from_string(parts[3], Color.WHITE)


static func _parse_points(layout: KitchenLayout, lines: Array) -> void:
	for line in lines:
		var parts := String(line).strip_edges().split(" ", false)
		if parts.size() < 3:
			continue
		var kind := PointKind.PICKUP
		if parts[0].to_lower().begins_with("deliv"):
			kind = PointKind.DELIVERY
		layout.points[Vector2i(int(parts[1]), int(parts[2]))] = kind


static func _parse_furniture(layout: KitchenLayout, lines: Array) -> void:
	for line in lines:
		var parts := String(line).strip_edges().split(" ", false)
		if parts.size() < 4:
			continue
		var tints := {}
		for i in range(4, parts.size()):
			var token: String = parts[i]
			if token.contains("="):
				var kv := token.split("=", false)
				if kv.size() == 2:
					var key := kv[0]
					if key == "tint":
						key = "*"
					tints[key] = Color.from_string(kv[1], Color.WHITE)
			else:
				# Older files: a bare colour token means the whole piece.
				var col := Color.from_string(token, Color.TRANSPARENT)
				if col.a > 0.0:
					tints["*"] = col
		layout.furniture.append({
			"id": StringName(parts[0]),
			"cell": Vector2i(int(parts[1]), int(parts[2])),
			"steps": int(parts[3]),
			"tints": tints,
		})


static func _store_edge(layout: KitchenLayout, cell: Vector2i, dir: int, kind: int) -> void:
	if kind < 0:
		return
	# Only store what differs from the derived default, so text files stay sparse.
	if layout.get_wall(cell, dir) == kind:
		return
	layout.set_wall(cell, dir, kind)


static func _line_char(line: String, index: int) -> String:
	return line[index] if index >= 0 and index < line.length() else " "


func _cell_char(cell: Vector2i) -> String:
	match get_floor(cell):
		Floor.TILE: return CELL_FLOOR
		Floor.PLATING: return CELL_PLATING
	return " "


func _edge_char(cell: Vector2i, dir: int) -> String:
	var kind := get_wall_key(edge_key(cell, dir))
	if kind == Wall.OPEN:
		return " "
	# Solid walls read as "|" when vertical and "-" when horizontal (both parse
	# back the same way); windows / doorways / low walls use their own letter.
	if kind == Wall.SOLID:
		return "|" if dir == DIR_X else "-"
	return WALL_CHAR.get(kind, "-")


func _vertex_char(x: int, z: int) -> String:
	for e in [
		Vector3i(x - 1, z - 1, DIR_X),
		Vector3i(x - 1, z, DIR_X),
		Vector3i(x - 1, z - 1, DIR_Z),
		Vector3i(x, z - 1, DIR_Z),
	]:
		if get_wall_key(e) != Wall.OPEN:
			return "+"
	return " "
