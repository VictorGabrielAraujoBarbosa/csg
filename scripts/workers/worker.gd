class_name Worker
extends Node3D
## A chibi kitchen worker. (Currently a toilet, as requested — the mesh is a
## placeholder for a proper character.)
##
## The simulation part ([method tick]) only knows cells and ticks: claim a job,
## walk the grid, operate a station, carry one item. The visual part
## ([method _process]) interpolates in real time: gliding between cells, a walk
## bob, a work bob and the carried item held in front.

enum State { IDLE, TO_HOME, TO_PICKUP, TO_DROP, TO_WORK, WORK, FLEE }

const TOILET_SCENE := "res://assets/kenney_furniture-kit/Models/GLTF format/toilet.glb"

var service: Service
var cell := Vector2i.ZERO
## Where this worker belongs: its placed post. It walks back here when idle.
var spawn_cell := Vector2i.ZERO
var state := State.IDLE
var job: Job = null
var tint_color := Color.WHITE
## Eaten by a customer: gone for the rest of the day (the post restaffs later).
var eaten := false

var _path: Array[Vector2i] = []
var _path_index := 0
var _cell_ticks := 0
var _work_left := 0
var _carrying: WorldItem = null

var _visual_from := Vector3.ZERO
var _visual_to := Vector3.ZERO
var _move_elapsed := 0.0
var _move_duration := 0.0
var _bob := 0.0
var _facing := 0.0
var _body: Node3D
var _hands: Node3D
var _mesh_height := 0.0


func setup(p_service: Service, start_cell: Vector2i, tint := Color.WHITE) -> void:
	service = p_service
	cell = start_cell
	spawn_cell = start_cell
	name = "Worker"
	tint_color = tint if not tint.is_equal_approx(Color.WHITE) else service.worker_tint
	_body = Node3D.new()
	add_child(_body)
	var scene := load(TOILET_SCENE) as PackedScene
	var model := scene.instantiate() as Node3D
	model.scale = Vector3.ONE * service.worker_scale
	_body.add_child(model)
	var aabb := MeshBounds.combined_aabb(model)
	if aabb.size != Vector3.ZERO:
		var center := aabb.get_center()
		model.position -= Vector3(center.x, aabb.position.y, center.z)
		_mesh_height = aabb.size.y
	_tint_body(tint_color)
	_hands = Node3D.new()
	_hands.position = Vector3(0.0, _mesh_height * 0.55, 0.42)
	add_child(_hands)
	_visual_from = _cell_world(cell)
	_visual_to = _visual_from
	position = _visual_from


func hands() -> Node3D:
	return _hands


func _tint_body(tint: Color) -> void:
	if tint.is_equal_approx(Color.WHITE):
		return
	var stack: Array[Node] = [_body]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			if mi.mesh != null:
				for i in mi.mesh.get_surface_count():
					var src := mi.mesh.surface_get_material(i)
					if src is BaseMaterial3D:
						var mat := (src as BaseMaterial3D).duplicate() as BaseMaterial3D
						mat.albedo_color = mat.albedo_color * tint
						mi.set_surface_override_material(i, mat)
		for child in node.get_children():
			stack.append(child)


func carried() -> WorldItem:
	return _carrying


func state_name() -> String:
	match state:
		State.IDLE:
			return "idle"
		State.TO_HOME:
			return "returning"
		State.TO_PICKUP:
			return "fetching"
		State.TO_DROP:
			return "carrying"
		State.TO_WORK:
			return "walking"
		State.WORK:
			return "working"
		State.FLEE:
			return "fleeing"
	return "?"


# ---------------------------------------------------------------------------
# Simulation (ticks)
# ---------------------------------------------------------------------------

func tick(_now: int) -> void:
	if job != null and job.state != Job.State.ACTIVE:
		_abort()
		return
	match state:
		State.IDLE:
			if cell != spawn_cell:
				_go_home()
		State.TO_HOME, State.TO_PICKUP, State.TO_DROP, State.TO_WORK, State.FLEE:
			_advance_path()
		State.WORK:
			_work_left -= 1
			if _work_left <= 0:
				_finish_work()


## Walks back onto the post itself (a mat is walkable, unlike a station).
func _go_home() -> void:
	var path := Pathfinder.find_path(service.kitchen, cell, spawn_cell)
	if path.is_empty():
		return
	_path = path
	_path_index = 0
	_cell_ticks = 0
	state = State.TO_HOME


## Called by the Service when the assignment pass picks this worker for a job.
func accept(new_job: Job) -> void:
	if new_job == null:
		return
	job = new_job
	if job.kind == Job.Kind.TRANSFER:
		_go_to(job.item.cell, State.TO_PICKUP)
	else:
		_go_to(job.station.work_target(), State.TO_WORK)


## Removed from the kitchen: drop what we hold and give up our job.
func despawn() -> void:
	force_idle()
	queue_free()


## Drops anything carried, forgets the current job and goes idle (used when the
## world is reset between test scenarios).
func force_idle() -> void:
	if _carrying != null:
		service.drop_carried(_carrying, cell)
		_carrying = null
	if job != null:
		service.board.cancel(job, "reset")
		job = null
	state = State.IDLE
	_path = []
	_path_index = 0
	_cell_ticks = 0


## Plans a walk to a cell next to [param target_cell].
func _go_to(target_cell: Vector2i, new_state: int) -> void:
	var stand := Pathfinder.adjacent_walkable(service.kitchen, target_cell, cell)
	if stand.x < -1000:
		_fail("nowhere to stand next to %s" % target_cell)
		return
	var path := Pathfinder.find_path(service.kitchen, cell, stand)
	if path.is_empty():
		_fail("no path to %s" % target_cell)
		return
	_path = path
	_path_index = 0
	_cell_ticks = 0
	state = new_state


## Panic: drop what we are doing and run to the cell farthest from any customer.
## Called by the Service every few ticks while the mob is inside.
func flee_from(threats: Array[Vector2i]) -> void:
	if eaten or threats.is_empty():
		return
	if _carrying != null:
		service.drop_carried(_carrying, cell, job.parent if job != null else null)
		_carrying = null
	if job != null:
		service.board.cancel(job, "fleeing")
		job = null
	var goal := _flee_target(threats)
	if goal.x < -1000 or goal == cell:
		state = State.FLEE if goal.x > -1000 else state
		return
	var path := Pathfinder.find_path(service.kitchen, cell, goal)
	if path.is_empty():
		return
	_path = path
	_path_index = 0
	_cell_ticks = 0
	state = State.FLEE


## The walkable cell (within a small radius) that is farthest from every threat.
func _flee_target(threats: Array[Vector2i]) -> Vector2i:
	var best := Vector2i(-2147483647, -2147483647)
	var best_score := -1
	var radius := 7
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var candidate := cell + Vector2i(dx, dz)
			if not service.kitchen.is_walkable(candidate):
				continue
			var nearest := 1 << 30
			for threat in threats:
				nearest = mini(nearest, absi(threat.x - candidate.x) + absi(threat.y - candidate.y))
			if nearest > best_score:
				best_score = nearest
				best = candidate
	return best


func _advance_path() -> void:
	_cell_ticks += 1
	if _cell_ticks < maxi(service.walk_ticks_per_cell, 1):
		return
	_cell_ticks = 0
	if _path_index + 1 < _path.size():
		_path_index += 1
		cell = _path[_path_index]
		_begin_step(cell)
	else:
		_on_arrived()


func _on_arrived() -> void:
	match state:
		State.TO_HOME:
			state = State.IDLE
		State.FLEE:
			state = State.IDLE
			_go_home()
		State.TO_PICKUP:
			_carrying = service.pick_up(job, self)
			if _carrying == null:
				_fail("the item vanished before pickup")
				return
			_go_to(job.target_cell, State.TO_DROP)
		State.TO_WORK:
			state = State.WORK
			_work_left = maxi(job.recipe.duration_ticks, 1)
			service.work_started.emit(self, job)
		State.TO_DROP:
			service.finish_transfer(job)
			_carrying = null
			_finish_job()


func _finish_work() -> void:
	service.finish_produce(job, self)
	_finish_job()


func _finish_job() -> void:
	job = null
	state = State.IDLE
	_path = []
	_path_index = 0
	_cell_ticks = 0


func _fail(reason: String) -> void:
	if job != null:
		service.fail_job(job, reason)
	if _carrying != null:
		service.drop_carried(_carrying, cell)
		_carrying = null
	_finish_job()


## The job disappeared (cancelled/replanned) while we were working on it.
func _abort() -> void:
	if _carrying != null:
		service.drop_carried(_carrying, cell)
		_carrying = null
	_finish_job()


# ---------------------------------------------------------------------------
# Presentation (real time, never tick-bound)
# ---------------------------------------------------------------------------

func _cell_world(c: Vector2i) -> Vector3:
	return Vector3(c.x, 0.0, c.y)


func _begin_step(next_cell: Vector2i) -> void:
	_visual_from = position
	_visual_to = _cell_world(next_cell)
	_move_elapsed = 0.0
	_move_duration = maxf(float(service.walk_ticks_per_cell) * service.tick_seconds(), 0.05)
	var dir := _visual_to - _visual_from
	if dir.length_squared() > 0.001:
		_facing = atan2(dir.x, dir.z)


func _process(delta: float) -> void:
	if service == null:
		return
	if _move_duration > 0.0:
		_move_elapsed = minf(_move_elapsed + delta, _move_duration)
		var t := _move_elapsed / _move_duration
		position = _visual_from.lerp(_visual_to, smoothstep(0.0, 1.0, t))
		_bob += delta * 16.0
		if _move_elapsed >= _move_duration:
			_move_duration = 0.0
			position = _visual_to
	if state == State.WORK:
		_bob += delta * 11.0
	rotation.y = lerp_angle(rotation.y, _facing, 1.0 - exp(-12.0 * delta))
	var lift := 0.0
	if _move_duration > 0.0:
		lift = absf(sin(_bob)) * 0.05
	elif state == State.WORK:
		lift = absf(sin(_bob)) * 0.035
	elif state == State.IDLE and cell == spawn_cell:
		_bob += delta * 3.0
		lift = (sin(_bob) * 0.5 + 0.5) * 0.012
	_body.position.y = lift
	_body.rotation.x = sin(_bob) * 0.07 if state == State.WORK else 0.0
