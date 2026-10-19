class_name Customer
extends Node3D
## A placeholder horror customer: a radioactive-green toilet that climbs in
## through a smashed window, hunts the nearest worker and eats it.
##
## Like [Worker], the simulation half ([method tick]) only knows cells and ticks
## — pick a target, A* to it, eat it on contact — while [method _process]
## interpolates the view in real time (glide, chunky hop, glow pulse).
##
## The hunt paths in [b]ghost mode[/b] ([method Pathfinder.find_path] with
## `ghost = true`): the mob walks through walls and over furniture, so a counter
## or a closed wall can never stall the attack (see
## [method Kitchen.walkable_for_ghost]). The workers keep the strict rules.

enum State { HUNT, EAT }

const TOILET_SCENE := "res://assets/kenney_furniture-kit/Models/GLTF format/toilet.glb"
const GREEN := Color(0.35, 1.0, 0.25)
## "No cell": the sentinel a forgotten chase stores (never a real grid cell).
const NO_CELL := Vector2i(-9999, -9999)
## Ticks between retries when the prey cannot be reached at all (a floor island
## the customer's floor does not touch). A hunt never re-searches every tick.
const REPATH_TICKS := 10

var service: Service
var cell := Vector2i.ZERO
var state := State.HUNT
var meals := 0
var tint_color := GREEN
## How many times the hunt re-planned its path. Tools read this: a customer with
## nobody to chase, or with an unreachable prey, must leave it nearly flat.
var repaths := 0

var _target: Worker = null
var _target_cell := NO_CELL
var _eat_left := 0
var _enter_left := 0
var _path: Array[Vector2i] = []
var _path_index := 0
var _cell_ticks := 0
var _retry_left := 0

var _visual_from := Vector3.ZERO
var _visual_to := Vector3.ZERO
var _move_elapsed := 0.0
var _move_duration := 0.0
var _hop := 0.0
var _facing := 0.0
var _body: Node3D
var _mesh_height := 0.0
var _materials: Array[StandardMaterial3D] = []


func setup(p_service: Service, start_cell: Vector2i, tint := GREEN) -> void:
	service = p_service
	cell = _entry_cell(start_cell)
	tint_color = tint
	name = "Customer"
	_body = Node3D.new()
	add_child(_body)
	var scene := load(TOILET_SCENE) as PackedScene
	var model := scene.instantiate() as Node3D
	model.scale = Vector3.ONE * (service.customer_scale if service != null else 2.0)
	_body.add_child(model)
	var aabb := MeshBounds.combined_aabb(model)
	if aabb.size != Vector3.ZERO:
		var center := aabb.get_center()
		model.position -= Vector3(center.x, aabb.position.y, center.z)
		_mesh_height = aabb.size.y
	_glow()
	_enter_left = service.customer_enter_ticks if service != null else 0
	_visual_from = _cell_world(cell)
	_visual_to = _visual_from
	position = _visual_from


func state_name() -> String:
	return "hunting" if state == State.HUNT else "eating"


func target() -> Worker:
	return _target


# ---------------------------------------------------------------------------
# Simulation (ticks)
# ---------------------------------------------------------------------------

func tick(_now: int) -> void:
	if _enter_left > 0:
		# Climbing in through the window: a short, dramatic pause.
		_enter_left -= 1
		return
	match state:
		State.EAT:
			_eat_left -= 1
			if _eat_left <= 0:
				state = State.HUNT
				_forget_hunt()
		State.HUNT:
			_hunt()


func _hunt() -> void:
	var prey := _pick_prey()
	if prey == null:
		# Nobody left to eat (the service ends the mob when the last worker
		# goes): stand still instead of re-planning an empty hunt every tick.
		_forget_hunt()
		return
	if prey.cell == cell:
		service.eat_worker(prey, self)
		meals += 1
		state = State.EAT
		_eat_left = maxi(service.customer_chew_ticks, 1)
		_forget_hunt()
		return
	# Re-plan the moment the prey moves (the path was built to its old cell),
	# and retry on a slow cooldown when there is no route at all — a customer
	# that cannot reach anyone stands its ground rather than searching forever.
	if prey != _target or prey.cell != _target_cell or (_path.is_empty() and _retry_left <= 0):
		_target = prey
		_target_cell = prey.cell
		_path = Pathfinder.find_path(service.kitchen, cell, prey.cell, [], true)
		_path_index = 0
		repaths += 1
		_retry_left = REPATH_TICKS if _path.is_empty() else 0
	if _path.is_empty():
		_retry_left = maxi(_retry_left - 1, 0)
		return
	_cell_ticks += 1
	if _cell_ticks < maxi(service.customer_ticks_per_cell, 1):
		return
	_cell_ticks = 0
	if _path_index + 1 < _path.size():
		_path_index += 1
		cell = _path[_path_index]
		_begin_step(cell)


## Drops the current chase (the prey was eaten, or there is nobody left).
func _forget_hunt() -> void:
	_target = null
	_target_cell = NO_CELL
	_path.clear()
	_path_index = 0
	_retry_left = 0


## The cell the customer actually appears on. The service spawns it on the
## window edge's inside cell, but a piece placed against the window can cover
## that cell (the service then falls back to the cell outside the wall). A ghost
## has to start on floor to walk anywhere, so take the nearest floor cell: the
## monster climbs in one cell further instead of standing outside forever.
func _entry_cell(start: Vector2i) -> Vector2i:
	var kitchen := service.kitchen if service != null else null
	if kitchen == null or kitchen.walkable_for_ghost(start):
		return start
	var seen := {start: true}
	var queue: Array[Vector2i] = [start]
	var visited := 0
	while not queue.is_empty() and visited < 256:
		var current: Vector2i = queue.pop_front()
		visited += 1
		for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next: Vector2i = current + step
			if seen.has(next):
				continue
			seen[next] = true
			if kitchen.walkable_for_ghost(next):
				return next
			queue.append(next)
	return start


## The closest living worker (Manhattan distance, stable tie-break by order).
func _pick_prey() -> Worker:
	var best: Worker = null
	var best_dist := 1 << 30
	for worker in service.workers:
		if worker.eaten:
			continue
		var dist := absi(worker.cell.x - cell.x) + absi(worker.cell.y - cell.y)
		if dist < best_dist:
			best_dist = dist
			best = worker
	return best


func despawn() -> void:
	queue_free()


# ---------------------------------------------------------------------------
# Presentation (real time)
# ---------------------------------------------------------------------------

## Where a customer stands on a cell: on the floor, or on top of whatever it is
## walking over (a counter, a structural table). Presentation only — the
## simulation is the grid cell; this is just so a ghost reads as climbing over
## the furniture rather than wading through it.
func _cell_world(c: Vector2i) -> Vector3:
	var y := 0.0
	if service != null and service.kitchen != null:
		y = maxf(service.kitchen.surface_height(c) - 0.05, 0.0)
	return Vector3(c.x, y, c.y)


func _begin_step(next_cell: Vector2i) -> void:
	_visual_from = position
	_visual_to = _cell_world(next_cell)
	_move_elapsed = 0.0
	_move_duration = maxf(float(service.customer_ticks_per_cell) * service.tick_seconds(), 0.05)
	var dir := _visual_to - _visual_from
	if dir.length_squared() > 0.001:
		_facing = atan2(dir.x, dir.z)


## Radioactive glow: the placeholder art is just the toilet mesh in a loud green.
func _glow() -> void:
	var stack: Array[Node] = [_body]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if mi.mesh != null:
				for i in mi.mesh.get_surface_count():
					var src := mi.mesh.surface_get_material(i)
					var mat := StandardMaterial3D.new()
					if src is BaseMaterial3D:
						mat.albedo_color = (src as BaseMaterial3D).albedo_color * tint_color
					else:
						mat.albedo_color = tint_color
					mat.emission_enabled = true
					mat.emission = tint_color
					mat.emission_energy_multiplier = 0.55
					mi.set_surface_override_material(i, mat)
					_materials.append(mat)
		for child in node.get_children():
			stack.append(child)


func _process(delta: float) -> void:
	if service == null:
		return
	if _move_duration > 0.0:
		_move_elapsed = minf(_move_elapsed + delta, _move_duration)
		var t := _move_elapsed / _move_duration
		position = _visual_from.lerp(_visual_to, smoothstep(0.0, 1.0, t))
		if _move_elapsed >= _move_duration:
			_move_duration = 0.0
			position = _visual_to
	_hop += delta * 9.0
	rotation.y = lerp_angle(rotation.y, _facing, 1.0 - exp(-10.0 * delta))
	var lift := 0.0
	if _move_duration > 0.0:
		lift = absf(sin(_hop)) * 0.16
	elif state == State.EAT:
		lift = absf(sin(_hop * 2.2)) * 0.08
	_body.position.y = lift
	_body.rotation.x = sin(_hop * 1.7) * 0.12
	var pulse := 0.45 + (sin(_hop * 0.8) * 0.5 + 0.5) * 0.35
	for mat in _materials:
		mat.emission_energy_multiplier = pulse
