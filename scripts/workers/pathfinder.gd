class_name Pathfinder
extends RefCounted
## A* over the kitchen grid, 4-way. A worker walks on floor cells and may only
## cross open or doorway edges — exactly the same rules the placement system
## uses, so what you build is what the chibis can navigate.

const NO_PATH: Array[Vector2i] = []


## Returns the path from [param from] to [param to] (inclusive), or an empty
## array when there is no way through.
static func find_path(kitchen: Kitchen, from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	if kitchen == null:
		return NO_PATH
	if from == to:
		return [from]
	if not kitchen.is_walkable(to) or not kitchen.is_walkable(from):
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
			if not kitchen.is_walkable(next):
				continue
			if not kitchen.can_cross(current, next):
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
static func adjacent_walkable(kitchen: Kitchen, target: Vector2i, from: Vector2i) -> Vector2i:
	var best := Vector2i(-2147483647, -2147483647)
	var best_dist := 1 << 30
	for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var cell: Vector2i = target + step
		if not kitchen.is_walkable(cell):
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


static func _reconstruct(came_from: Dictionary, current: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = [current]
	while came_from.has(current) and came_from[current] != current:
		current = came_from[current]
		path.append(current)
	path.reverse()
	return path
