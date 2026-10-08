class_name ItemManager
extends Node3D
## Owns every item in the world: spawning, moving, reserving and consuming.
## Items live on cells (stations, points or bare floor) and are laid out with a
## small offset when several share a cell.

signal items_changed

const MAX_PER_CELL := 4

var items: Array[WorldItem] = []

var _by_cell: Dictionary = {}  # Vector2i -> Array[WorldItem]
var _root: Node3D


func _ready() -> void:
	_root = Node3D.new()
	_root.name = "Items"
	add_child(_root)


func spawn(def: ItemDef, cell: Vector2i, amount: int, payload: Dictionary, height: float) -> WorldItem:
	var item := WorldItem.new()
	item.setup(def, amount, payload, cell, height, def.tint)
	_root.add_child(item)
	items.append(item)
	if not _by_cell.has(cell):
		_by_cell[cell] = []
	(_by_cell[cell] as Array).append(item)
	_merge_cell(cell)
	_layout_cell(cell)
	items_changed.emit()
	return item


## Starts the visual journey of a carried item (real seconds, not ticks).
func begin_carry(item: WorldItem, cell: Vector2i, height: float, duration: float) -> void:
	if item == null:
		return
	item.begin_move(WorldItem.cell_position(cell, height), duration)


## Finishes a carry: the item logically arrives and settles into its slot.
func finish_carry(item: WorldItem, cell: Vector2i, height: float) -> void:
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
	_merge_cell(cell)
	_layout_cell(old)
	_layout_cell(cell)
	items_changed.emit()


func remove(item: WorldItem) -> void:
	if item == null or not items.has(item):
		return
	items.erase(item)
	if _by_cell.has(item.cell):
		(_by_cell[item.cell] as Array).erase(item)
		_layout_cell(item.cell)
	item.queue_free()
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


## Consumes [param amount] from a stack, freeing it when empty.
func consume(item: WorldItem, amount: int) -> void:
	item.amount -= amount
	if item.amount <= 0:
		remove(item)
	else:
		items_changed.emit()


## Total amount of an item id across the world (for tests / UI).
func count(item_id: StringName) -> int:
	var total := 0
	for item in items:
		if item.def.id == item_id:
			total += item.amount
	return total


## Merges identical, unreserved stacks on a cell so amounts add up (two
## tomatoes transferred one by one become one stack of two).
func _merge_cell(cell: Vector2i) -> void:
	var list: Array = _by_cell.get(cell, [])
	var i := 0
	while i < list.size():
		var a: WorldItem = list[i]
		var j := i + 1
		while j < list.size():
			var b: WorldItem = list[j]
			if a.reserved_by == null and b.reserved_by == null \
					and a.def.id == b.def.id and a.payload == b.payload:
				a.amount += b.amount
				list.remove_at(j)
				items.erase(b)
				b.queue_free()
			else:
				j += 1
		i += 1


func _layout_cell(cell: Vector2i) -> void:
	var cell_items: Array = _by_cell.get(cell, [])
	var index := 0
	var count := maxi(cell_items.size(), 2)
	for item: WorldItem in cell_items:
		var offset := Vector3.ZERO
		if index > 0:
			# Spread stacked items in a small fan so they stay readable.
			var angle := TAU * float(index) / float(count)
			offset = Vector3(cos(angle), 0.0, sin(angle)) * 0.3
		item.rotation_degrees = Vector3(0.0, float(index) * 37.0, 0.0)
		item.set_layout_target(WorldItem.cell_position(cell, item.base_height) + offset)
		index += 1
