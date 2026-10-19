class_name Pathfinder
extends RefCounted
## A* over the kitchen grid, 4-way. A worker walks on floor cells and may only
## cross open or doorway edges — exactly the same rules the placement system
## uses, so what you build is what the chibis can navigate.

const NO_PATH: Array[Vector2i] = []


## Returns the path from [param from] to [param to] (inclusive), or an empty
## array when there is no way through.
## [param avoid] holds cells to route around (tiles a worker is operating from).
## The caller MUST be ready to retry without it: avoidance can make a target
## unreachable, and a fallback is what keeps this from ever blocking anyone.
##
## [param ghost] switches to the horror customers' rules: every floor cell is
## walkable and every edge can be crossed, so a hunt can never stall behind a
## counter or a wall (see [method Kitchen.walkable_for_ghost]). The workers keep
## the strict rules; this is the same search either way, only the two predicates
## change. A ghost may even *start* off the floor — the service drops it on the
## window cell, which a piece placed against the window can cover — so only the
## target has to be a real cell; the search simply steps out of the void.
static func find_path(kitchen: Kitchen, from: Vector2i, to: Vector2i, avoid: Array = [], ghost := false) -> Array[Vector2i]:
	if kitchen == null:
		return NO_PATH
	if from == to:
		return [from]
	if not _walkable(kitchen, to, ghost):
		return NO_PATH
	if not ghost and not kitchen.is_walkable(from):
		return NO_PATH

	var open: Array[Vector2i] = [from]
	var came_from := {from: from}
	var g := {from: 0}
	var f := {from: _heuristic(from, to)}

	while not open.is_empty():
		# Pick the lowest f (the grid is small; a scan is plenty).
		var best_index := 0
		for i in range(1, open.size()):
			if f.get(open[i], 1 << 30) < f.get(open[best_index], 1 << 30):
				best_index = i
		var current: Vector2i = open[best_index]
		if current == to:
			return _reconstruct(came_from, current)
		open.remove_at(best_index)

		for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next: Vector2i = current + step
			if not _walkable(kitchen, next, ghost):
				continue
			if next != to and avoid.has(next):
				continue
			if not _crossable(kitchen, current, next, ghost):
				continue
			var tentative: int = g[current] + 1
			if tentative < g.get(next, 1 << 30):
				came_from[next] = current
				g[next] = tentative
				f[next] = tentative + _heuristic(next, to)
				if not open.has(next):
					open.append(next)
	return NO_PATH


## A walkable cell adjacent to [param target] (preferring one closest to
## [param from]), or a sentinel when the target is unreachable by standing.
static func adjacent_walkable(kitchen: Kitchen, target: Vector2i, from: Vector2i, avoid: Array = []) -> Vector2i:
	var best := Vector2i(-2147483647, -2147483647)
	var best_dist := 1 << 30
	for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var cell: Vector2i = target + step
		if not kitchen.is_walkable(cell):
			continue
		if avoid.has(cell):
			continue
		if not kitchen.data.can_cross(target, cell):
			continue
		var dist := absi(cell.x - from.x) + absi(cell.y - from.y)
		if dist < best_dist:
			best_dist = dist
			best = cell
	return best


static func _heuristic(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


## The cell rule of the mode. Strict: the placement rules (floor, no solid piece,
## no structural point). Ghost: any floor cell at all. Both rules live in
## [Kitchen], so the search never second-guesses them.
static func _walkable(kitchen: Kitchen, cell: Vector2i, ghost: bool) -> bool:
	if ghost:
		return kitchen.walkable_for_ghost(cell)
	return kitchen.is_walkable(cell)


## The edge rule of the mode: open/doorway edges (and smashed windows) strictly,
## anything at all for a ghost.
static func _crossable(kitchen: Kitchen, a: Vector2i, b: Vector2i, ghost: bool) -> bool:
	if ghost:
		return kitchen.can_cross_ghost(a, b)
	return kitchen.can_cross(a, b)


static func _reconstruct(came_from: Dictionary, current: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = [current]
	while came_from.has(current) and came_from[current] != current:
		current = came_from[current]
		path.append(current)
	path.reverse()
	return path
