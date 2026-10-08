class_name ItemManager
extends Node3D
## Owns every item in the world: spawning, moving, reserving and consuming.
##
## Every item is a single entity that occupies exactly one slot. A cell has
## infinitely many slots for now (arranged in a growing lattice around its
## centre); [member max_slots_per_cell] is the hook for limiting them later.

signal items_changed

## 0 = unlimited (the future capacity limit lives here).
const MAX_SLOTS_PER_CELL := 0
## Distance between slots inside a cell (world units).
const SLOT_SPACING := 0.26

var items: Array[WorldItem] = []

var _by_cell: Dictionary = {}  # Vector2i -> Array[WorldItem]
var _root: Node3D


func _ready() -> void:
	_root = Node3D.new()
	_root.name = "Items"
	add_child(_root)


func root() -> Node3D:
	return _root


func has_room(cell: Vector2i) -> bool:
	if MAX_SLOTS_PER_CELL <= 0:
		return true
	return items_at(cell).size() < MAX_SLOTS_PER_CELL


func spawn(def: ItemDef, cell: Vector2i, payload: Dictionary, height: float) -> WorldItem:
	var item := WorldItem.new()
	item.setup(def, payload, cell, height, def.tint)
	_root.add_child(item)
	items.append(item)
	if not _by_cell.has(cell):
		_by_cell[cell] = []
	(_by_cell[cell] as Array).append(item)
	_layout_cell(cell)
	items_changed.emit()
	return item


func remove(item: WorldItem) -> void:
	if item == null or not items.has(item):
		return
	items.erase(item)
	var old := item.cell
	if _by_cell.has(old):
		(_by_cell[old] as Array).erase(item)
		_layout_cell(old)
	item.queue_free()
	items_changed.emit()


## Starts a carry: the item leaves its cell immediately (so the cell re-lays
## out) and glides towards the slot it will occupy at the destination.
func begin_carry(item: WorldItem, cell: Vector2i, height: float, duration: float) -> void:
	if item == null:
		return
	var source := item.cell
	if _by_cell.has(source):
		(_by_cell[source] as Array).erase(item)
		_layout_cell(source)
	var index := items_at(cell).size()
	item.begin_move(WorldItem.cell_position(cell, height) + slot_offset(index), duration)
	items_changed.emit()


## Removes the item from its cell (a worker just picked it up). It stays in the
## world list and keeps its job reservation.
func detach_for_carry(item: WorldItem) -> void:
	if item == null:
		return
	if _by_cell.has(item.cell):
		(_by_cell[item.cell] as Array).erase(item)
		_layout_cell(item.cell)
	items_changed.emit()


## Finishes a carry: the item lands in the next free slot of the destination
## (and comes back from a worker's hands into the world layer).
func finish_carry(item: WorldItem, cell: Vector2i, height: float) -> void:
	if item == null:
		return
	var index := items_at(cell).size()
	var pos := WorldItem.cell_position(cell, height) + slot_offset(index)
	item.detach_to(_root, pos)
	move(item, cell, height)


## Logical move (used when a carry completes).
func move(item: WorldItem, cell: Vector2i, height: float) -> void:
	var old := item.cell
	if _by_cell.has(old):
		(_by_cell[old] as Array).erase(item)
	item.cell = cell
	item.base_height = height
	if not _by_cell.has(cell):
		_by_cell[cell] = []
	(_by_cell[cell] as Array).append(item)
	_layout_cell(old)
	_layout_cell(cell)
	items_changed.emit()


func items_at(cell: Vector2i) -> Array[WorldItem]:
	var out: Array[WorldItem] = []
	for item: WorldItem in _by_cell.get(cell, []):
		out.append(item)
	return out


## A free (unreserved) item matching the request, preferring the nearest.
func find_free(item_id: StringName, order_id: int, needs_order: bool, near: Vector2i) -> WorldItem:
	var best: WorldItem = null
	var best_dist := 1 << 30
	for item in items:
		if item.reserved_by != null:
			continue
		if not item.matches(item_id, order_id, needs_order):
			continue
		var dist := absi(item.cell.x - near.x) + absi(item.cell.y - near.y)
		if dist < best_dist:
			best_dist = dist
			best = item
	return best


## Removes a single item from the world (it has been used by a recipe).
func consume(item: WorldItem) -> void:
	remove(item)


## How many items of this kind exist (for tests / UI).
func count(item_id: StringName) -> int:
	var total := 0
	for item in items:
		if item.def.id == item_id:
			total += 1
	return total


## Slot positions inside one cell: index 0 is the centre, then rings of a
## growing square lattice, so items never share a spot.
static func slot_offset(index: int) -> Vector3:
	while _slot_cache.size() <= index:
		_slot_cache.append(_make_slot(_slot_cache.size()))
	return _slot_cache[index]


static var _slot_cache: Array[Vector3] = []


static func _make_slot(index: int) -> Vector3:
	if index == 0:
		return Vector3.ZERO
	var ring := 1
	var placed := 1  # the centre slot
	while true:
		var span := ring * 2 + 1
		var perimeter := span * span - (span - 2) * (span - 2)
		if index < placed + perimeter:
			var step := index - placed
			var side := step / (span - 1)
			var t := step % (span - 1)
			var lo := -ring
			var hi := ring
			var x := 0
			var z := 0
			match side:
				0:
					x = lo
					z = lo + t
				1:
					x = lo + t
					z = hi
				2:
					x = hi
					z = hi - t
				_:
					x = hi - t
					z = lo
			return Vector3(x, 0.0, z) * SLOT_SPACING
		placed += perimeter
		ring += 1
	return Vector3.ZERO


func _layout_cell(cell: Vector2i) -> void:
	var cell_items: Array = _by_cell.get(cell, [])
	var index := 0
	for item: WorldItem in cell_items:
		item.rotation_degrees = Vector3(0.0, float(index) * 37.0, 0.0)
		item.set_layout_target(WorldItem.cell_position(cell, item.base_height) + slot_offset(index))
		index += 1
