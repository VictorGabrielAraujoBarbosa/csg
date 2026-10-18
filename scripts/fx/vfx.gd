class_name Vfx
extends Node3D
## Pooled, purely cosmetic effects driven by the simulation's event signals.
##
## Nothing here may feed back into the simulation (invariant 11): effects read
## cells/positions from [Kitchen] and are animated on the real-time clock, never
## on ticks. Every emitter is built in code (GPUParticles3D +
## [ParticleProcessMaterial] plus a generated radial alpha texture — there are no
## particle assets) and reused from a pool, so a long day does not leak nodes.
##
## Event -> effect mapping (see also [AudioBank], which plays the sounds):
##   [signal Service.work_started]   cooking job  -> steam wisps over the station
##                                   washing job  -> suds + droplets at the sink
##   [signal Service.work_finished]  any recipe   -> sparkle burst (small for take_*)
##                                   dishes       -> expanding ring (+ splash / steam puff)
##   [signal Service.item_dropped]   item lands   -> small dust puff
##   [signal Service.order_delivered] order done  -> confetti + ring + floating "+$25"
##   [signal Service.window_broken]  a window is smashed -> glass shard burst
##   [signal Service.worker_consumed] a worker is eaten -> green ooze puff
##   [signal Kitchen.layout_edited]  piece placed -> dust puff under the piece
##   [signal ItemManager.item_removed] consumed   -> tiny dust puff

@export var service_path: NodePath
@export var kitchen_path: NodePath
## The [AudioBank] this layer drives (every effect has a sound twin).
@export var audio_path: NodePath

@export_group("Pooling")
## Hard cap on simultaneously live particle emitters. A burst past the cap is
## dropped: effects are cosmetic and must never stall the game.
@export var max_live_particles := 48
## Minimum real seconds between two bursts of the same kind (spam guard).
@export var burst_cooldown := 0.05
## How long an emitter stays reserved after its particles should be gone before
## it returns to the pool, in real seconds.
@export var pool_margin := 0.35
## Torus pulses and money labels alive at once (pool sizes).
@export var ring_pool_size := 4
@export var label_pool_size := 4

@export_group("Steam (cooking)")
## Wisps alive at once while a station cooks.
@export var steam_amount := 18
## Real seconds one wisp lives.
@export var steam_lifetime := 1.6
@export var steam_speed_min := 0.3
@export var steam_speed_max := 0.8
@export var steam_spread := 24.0
@export var steam_size_min := 0.3
@export var steam_size_max := 0.7
## White with real alpha: the wall behind the stove is light, so grey steam
## disappears — it has to brighten what is behind it to read.
@export var steam_color := Color(1.0, 1.0, 1.0, 0.55)
## Second, slower and bigger layer that reads as the bulk of the plume.
@export var steam_soft_amount := 8
@export var steam_soft_size_min := 0.6
@export var steam_soft_size_max := 1.15
@export var steam_soft_color := Color(1.0, 1.0, 1.0, 0.3)
## Height above the station surface where the wisps start.
@export var steam_height := 0.3
## Upward drift of the wisps (m/s²; positive = rising).
@export var steam_rise := 0.2

@export_group("Splash (washing)")
## Suds bubbles alive at once while the sink runs.
@export var suds_amount := 10
@export var suds_lifetime := 1.1
@export var suds_size_min := 0.09
@export var suds_size_max := 0.24
## Also tinted towards blue so the foam reads against the white kitchen.
@export var suds_color := Color(0.8, 0.88, 1.0, 0.6)
## Droplets in the one-shot splash when a wash finishes.
@export var splash_amount := 18
@export var splash_lifetime := 0.55
@export var splash_speed_min := 1.0
@export var splash_speed_max := 2.2
@export var splash_size_min := 0.05
@export var splash_size_max := 0.13
@export var splash_color := Color(0.72, 0.88, 1.0, 0.95)

@export_group("Sparkle burst (produced)")
## Sparkles in the burst when a recipe finishes.
@export var sparkle_amount := 26
@export var sparkle_lifetime := 0.7
@export var sparkle_speed_min := 0.8
@export var sparkle_speed_max := 2.2
@export var sparkle_size_min := 0.07
@export var sparkle_size_max := 0.17
@export var sparkle_color := Color(1.0, 0.92, 0.55, 1.0)
## How much smaller the burst is for "take from storage" recipes (0..1).
@export_range(0.1, 1.0, 0.05) var sparkle_source_scale := 0.45
## Height above the output cell where the burst happens.
@export var sparkle_height := 0.18

@export_group("Dust puffs")
@export var dust_amount := 9
@export var dust_lifetime := 0.5
@export var dust_speed_min := 0.2
@export var dust_speed_max := 0.6
@export var dust_size_min := 0.1
@export var dust_size_max := 0.26
## Warm mid-grey: darker than both the white counters and the beige tables.
@export var dust_color := Color(0.55, 0.51, 0.45, 0.62)

@export_group("Confetti & money (delivery)")
@export var confetti_amount := 30
@export var confetti_lifetime := 1.1
@export var confetti_speed_min := 1.2
@export var confetti_speed_max := 2.6
@export var confetti_size_min := 0.05
@export var confetti_size_max := 0.11
@export var confetti_height := 0.35
## How long the floating "+$25" label lives and how far it rises.
@export var money_label_lifetime := 1.2
@export var money_label_rise := 0.9
@export var money_label_height := 0.75
@export var money_label_size := 0.011
@export var money_label_color := Color(0.45, 1.0, 0.5)

@export_group("Ring pulse")
@export var ring_lifetime := 0.45
@export var ring_start_scale := 0.25
@export var ring_end_scale := 1.3
@export var ring_alpha := 0.7

@export_group("Horror")
## Glass shards on [signal Service.window_broken] (the customers smash in).
@export var shard_amount := 34
@export var shard_lifetime := 1.0
@export var shard_speed_min := 1.6
@export var shard_speed_max := 3.4
@export var shard_size_min := 0.07
@export var shard_size_max := 0.17
## Strong cyan-blue: the glass has to read against the light walls.
@export var shard_color := Color(0.4, 0.75, 0.95, 0.95)
## Height of the burst on a broken wall edge.
@export var shard_height := 1.1
## Green ooze on [signal Service.worker_consumed].
@export var ooze_amount := 26
@export var ooze_lifetime := 0.8
@export var ooze_speed_min := 0.6
@export var ooze_speed_max := 1.8
@export var ooze_size_min := 0.08
@export var ooze_size_max := 0.2
@export var ooze_color := Color(0.35, 0.85, 0.25, 0.95)

var service: Service
var kitchen: Kitchen
var audio: AudioBank

## How many times each effect actually fired (tests / tools read this).
var stats: Dictionary = {}
## How many bursts the cooldown swallowed (proves the throttle works).
var throttled: Dictionary = {}
## The last few bursts, for dev tools: "kind @ pos" / "throttled" / "pool full".
var recent: Array[String] = []

var _particle_mesh: QuadMesh
var _soft_material: StandardMaterial3D
var _flat_material: StandardMaterial3D
var _materials: Dictionary = {}  # effect id -> ParticleProcessMaterial

var _free_particles: Array[GPUParticles3D] = []
var _live_particles: Array[GPUParticles3D] = []
var _expires: Dictionary = {}    # GPUParticles3D -> float (msec, or INF while looping)
var _last_burst: Dictionary = {} # throttle key -> float (msec)
var _loops: Dictionary = {}      # key (Worker or String) -> Array[GPUParticles3D]

var _free_rings: Array[MeshInstance3D] = []
var _active_rings: Array[MeshInstance3D] = []
var _ring_age: Dictionary = {}
var _ring_scale: Dictionary = {}
var _free_labels: Array[Label3D] = []
var _active_labels: Array[Label3D] = []
var _label_age: Dictionary = {}
var _label_base_y: Dictionary = {}

var _furniture_seen: Dictionary = {}
var _items_connected := false


func _ready() -> void:
	service = _resolve_node(service_path, "Service") as Service
	kitchen = _resolve_node(kitchen_path, "Kitchen") as Kitchen
	audio = _resolve_node(audio_path, "AudioBank") as AudioBank
	_build_shared_resources()
	if service != null:
		service.work_started.connect(_on_work_started)
		service.work_finished.connect(_on_work_finished)
		service.item_carried.connect(_on_item_carried)
		service.item_dropped.connect(_on_item_dropped)
		service.order_delivered.connect(_on_order_delivered)
		service.window_broken.connect(_on_window_broken)
		service.worker_consumed.connect(_on_worker_consumed)
		service.tick_passed.connect(_on_tick)
		_try_connect_items()
	if kitchen != null:
		kitchen.layout_rebuilt.connect(_snapshot_furniture)
		kitchen.layout_edited.connect(_on_layout_edited)
		_snapshot_furniture()


func _exit_tree() -> void:
	# Shared materials/meshes are ours; drop them so a reload does not leak.
	_materials.clear()


## Finds a sibling controller: the exported path wins, then the usual spots
## next to this node (Vfx sits under the world, next to Service / Kitchen).
func _resolve_node(path: NodePath, name_hint: String) -> Node:
	if not path.is_empty():
		var direct := get_node_or_null(path)
		if direct != null:
			return direct
	for candidate in ["../" + name_hint, "../../" + name_hint, "../../../" + name_hint]:
		var node := get_node_or_null(candidate)
		if node != null:
			return node
	var root := get_tree().current_scene
	if root == null:
		root = get_tree().root
	if root != null:
		return root.find_child(name_hint, true, false)
	return null


# ---------------------------------------------------------------------------
# Simulation events -> effects
# ---------------------------------------------------------------------------

## A worker arrived at a station and started working: long-running effects for
## the stations that need them (steam for cooking, suds for washing).
func _on_work_started(worker: Worker, job: Job) -> void:
	if job == null or job.recipe == null or job.station == null:
		return
	if audio != null:
		audio.play_work_start(job.recipe.id, _station_top(job.station))
	if job.station.has_tag(&"cooking"):
		_start_loop(worker, "steam", _station_top(job.station) + Vector3(0.0, steam_height, 0.0))
	elif job.station.has_tag(&"washing"):
		_start_loop(worker, "wash", _station_top(job.station) + Vector3(0.0, 0.12, 0.0))


## The work finished and its outputs were spawned: stop the loop, then burst at
## the station's output cell.
func _on_work_finished(worker: Worker, job: Job) -> void:
	if worker != null:
		_stop_loop(worker)
	if job == null or job.recipe == null or job.station == null:
		return
	var pos := _cell_top(job.station.output_cell())
	if audio != null:
		audio.play_work_finish(job.recipe.id, pos)
	var scale := sparkle_source_scale if job.recipe.is_source else 1.0
	_burst("sparkle", pos + Vector3(0.0, sparkle_height, 0.0), scale)
	if not job.recipe.is_source:
		_ring(pos + Vector3(0.0, 0.05, 0.0), sparkle_color)
	if job.station.has_tag(&"washing"):
		_burst("splash", pos + Vector3(0.0, 0.12, 0.0))
	elif job.station.has_tag(&"cooking"):
		_burst("steam_puff", pos + Vector3(0.0, steam_height, 0.0))


func _on_item_carried(item: WorldItem, worker: Worker) -> void:
	if audio != null and worker != null:
		audio.play_pickup(worker.global_position + Vector3(0.0, 0.5, 0.0))


## A carried item landed: a small dust puff where it hit the surface.
func _on_item_dropped(item: WorldItem, cell: Vector2i) -> void:
	_burst("dust", _cell_top(cell) + Vector3(0.0, 0.04, 0.0), 1.2, "dust_drop")
	if audio != null and item != null:
		audio.play_drop(item.def.id, _cell_top(cell))


## The order left the kitchen: confetti, a ring and the floating payout.
func _on_order_delivered(order: Order, cell: Vector2i) -> void:
	var pos := _cell_top(cell)
	_burst("confetti", pos + Vector3(0.0, confetti_height, 0.0))
	_ring(pos + Vector3(0.0, 0.06, 0.0), money_label_color, 1.15)
	var amount := 0
	if order != null:
		amount = order.reward
	elif service != null and service.orders != null:
		amount = service.orders.reward_per_order
	_money_label(pos + Vector3(0.0, money_label_height, 0.0), amount)
	if audio != null:
		audio.play_delivered(pos)


## A window is smashed open (the customers break in): shards fly from the wall.
func _on_window_broken(edge: Vector3i) -> void:
	var pos := _edge_world(edge)
	# one burst per edge, even when the whole mob comes through at once
	_burst("shards", pos, 1.0, "shards:%d:%d:%d" % [edge.x, edge.y, edge.z])
	if audio != null:
		audio.play_window_break(pos)


## A worker is eaten by a customer: green ooze where it stood.
func _on_worker_consumed(worker: Worker) -> void:
	var pos := Vector3.ZERO
	if worker != null and is_instance_valid(worker):
		pos = worker.global_position + Vector3(0.0, 0.35, 0.0)
		_burst("ooze", pos, 1.0, "ooze:%d" % worker.get_instance_id())
	else:
		_burst("ooze", pos)
	_ring(pos, ooze_color, 0.9)
	if audio != null:
		audio.play_worker_consumed(pos)


## An item left the world for good (a recipe consumed it): tiny dust puff.
func _on_item_removed(item: WorldItem) -> void:
	if item == null:
		return
	_burst("dust", _cell_top(item.cell) + Vector3(0.0, 0.05, 0.0), 0.45, "dust_remove")


## A piece of furniture appeared (placed, bought, moved or undone): dust puff on
## its top surface. Painting also emits [signal Kitchen.layout_edited], hence the
## diff against the pieces seen last time.
func _on_layout_edited() -> void:
	if kitchen == null:
		return
	var seen: Dictionary = {}
	for inst in kitchen.get_furniture_instances():
		var id := inst.get_instance_id()
		seen[id] = true
		if not _furniture_seen.has(id):
			var top := kitchen.surface_height(inst.anchor)
			var pos := Vector3(inst.global_position.x, top + 0.06, inst.global_position.z)
			_burst("dust", pos, 1.8, "dust_place")
			if audio != null:
				audio.play_place(pos)
	_furniture_seen = seen


func _snapshot_furniture() -> void:
	_furniture_seen.clear()
	if kitchen == null:
		return
	for inst in kitchen.get_furniture_instances():
		_furniture_seen[inst.get_instance_id()] = true


## Once per tick (cheap): stop station loops whose worker walked off, so a
## cancelled job does not leave steam running forever.
func _on_tick(_tick: int) -> void:
	_try_connect_items()
	if _loops.is_empty():
		return
	for key in _loops.keys():
		var worker := key as Worker
		if worker == null:
			continue
		if not is_instance_valid(worker) or worker.state != Worker.State.WORK or worker.job == null:
			_stop_loop(key)


func _try_connect_items() -> void:
	if _items_connected or service == null or service.items == null:
		return
	_items_connected = true
	service.items.item_removed.connect(_on_item_removed)


# ---------------------------------------------------------------------------
# Public triggers (tools, and the horror event when it lands)
# ---------------------------------------------------------------------------

## Fires one one-shot effect by name: "sparkle", "steam_puff", "splash",
## "dust", "confetti", "shards", "ooze". [param key] overrides the throttle
## key, so several bursts of the same kind can fire back to back.
func burst(kind: String, position: Vector3, scale := 1.0, key := "") -> void:
	_burst(kind, position, scale, key)


## Starts a looping effect by name ("steam", "wash") at a world position, keyed
## so it can be stopped again (pass a Worker to have it stop automatically).
func start_loop(kind: String, position: Vector3, key: Variant = "manual") -> void:
	_start_loop(key, kind, position)


func stop_loop(key: Variant = "manual") -> void:
	_stop_loop(key)


func live_particle_count() -> int:
	return _live_particles.size()


func pooled_particle_count() -> int:
	return _live_particles.size() + _free_particles.size()


# ---------------------------------------------------------------------------
# Pooling
# ---------------------------------------------------------------------------

func _acquire_particle(cfg: Dictionary, pos: Vector3, loop: bool) -> GPUParticles3D:
	var node: GPUParticles3D = null
	if not _free_particles.is_empty():
		node = _free_particles.pop_back()
	elif _live_particles.size() + _free_particles.size() < max_live_particles:
		node = _new_particle()
	if node == null:
		return null
	node.process_material = _process_material(cfg)
	node.material_override = _soft_material if cfg.get("material", "soft") == "soft" else _flat_material
	node.amount = int(cfg.get("amount", 8))
	node.lifetime = float(cfg.get("lifetime", 0.6))
	node.one_shot = not loop
	node.explosiveness = 0.0 if loop else float(cfg.get("explosiveness", 0.9))
	node.randomness = float(cfg.get("randomness", 0.35))
	node.preprocess = float(cfg.get("preprocess", 0.0))
	node.global_position = pos
	node.emitting = false
	node.restart()
	node.emitting = true
	_live_particles.append(node)
	_expires[node] = INF if loop else float(Time.get_ticks_msec()) + (node.lifetime + pool_margin) * 1000.0
	return node


func _release_particle(node: GPUParticles3D) -> void:
	node.emitting = false
	var index := _live_particles.find(node)
	if index >= 0:
		_live_particles.remove_at(index)
	_expires.erase(node)
	if not _free_particles.has(node):
		_free_particles.append(node)


func _new_particle() -> GPUParticles3D:
	var node := GPUParticles3D.new()
	node.name = "FxParticles"
	node.draw_pass_1 = _particle_mesh
	node.local_coords = true
	node.emitting = false
	node.one_shot = true
	add_child(node)
	return node


func _burst(kind: String, pos: Vector3, scale := 1.0, key := "") -> void:
	var throttle_key := key if not key.is_empty() else kind
	var now := Time.get_ticks_msec()
	if now - float(_last_burst.get(throttle_key, -1.0e9)) < burst_cooldown * 1000.0:
		_bump(throttled, kind)
		_log_burst("%s @ %s throttled" % [throttle_key, pos])
		return
	_last_burst[throttle_key] = float(now)
	var spawned := 0
	for cfg: Dictionary in _layers(kind, scale):
		# the material cache is keyed by id, so a scaled burst needs its own id
		if not is_equal_approx(scale, 1.0):
			cfg["id"] = "%s:%s" % [str(cfg.get("id", kind)), str(scale)]
		if _acquire_particle(cfg, pos, false) != null:
			spawned += 1
	if spawned > 0:
		_bump(stats, kind)
		_log_burst("%s @ %s" % [throttle_key, pos])
	else:
		_log_burst("%s @ %s dropped (pool full)" % [throttle_key, pos])


func _log_burst(text: String) -> void:
	recent.append("[t%d] %s" % [Time.get_ticks_msec(), text])
	if recent.size() > 200:
		recent.pop_front()


func _start_loop(key: Variant, kind: String, pos: Vector3) -> void:
	_stop_loop(key)
	var nodes: Array[GPUParticles3D] = []
	for cfg: Dictionary in _layers(kind, 1.0):
		var node := _acquire_particle(cfg, pos, true)
		if node == null:
			break
		nodes.append(node)
	if nodes.is_empty():
		return
	_loops[key] = nodes
	_bump(stats, kind)


func _stop_loop(key: Variant) -> void:
	if not _loops.has(key):
		return
	var nodes: Array = _loops[key]
	_loops.erase(key)
	var now := float(Time.get_ticks_msec())
	for node: GPUParticles3D in nodes:
		node.emitting = false
		_expires[node] = now + (node.lifetime + pool_margin) * 1000.0


func _bump(dict: Dictionary, key: String) -> void:
	dict[key] = int(dict.get(key, 0)) + 1


# ---------------------------------------------------------------------------
# Effect recipes (one entry per particle layer)
# ---------------------------------------------------------------------------

func _layers(kind: String, scale: float) -> Array:
	match kind:
		"steam":
			return [{
				"id": "steam",
				"amount": steam_amount, "lifetime": steam_lifetime, "one_shot": false,
				"preprocess": steam_lifetime * 0.6, "randomness": 0.5,
				"direction": Vector3.UP, "spread": steam_spread,
				"speed_min": steam_speed_min, "speed_max": steam_speed_max,
				"gravity": Vector3(0.0, steam_rise, 0.0),
				"size_min": steam_size_min, "size_max": steam_size_max,
				"color": steam_color, "fade": 0.3, "radius": 0.07,
				"material": "soft",
			}, {
				"id": "steam_soft",
				"amount": steam_soft_amount, "lifetime": steam_lifetime * 1.25, "one_shot": false,
				"preprocess": steam_lifetime * 0.9, "randomness": 0.6,
				"direction": Vector3.UP, "spread": steam_spread + 14.0,
				"speed_min": steam_speed_min * 0.5, "speed_max": steam_speed_max * 0.5,
				"gravity": Vector3(0.0, steam_rise * 0.6, 0.0),
				"size_min": steam_soft_size_min, "size_max": steam_soft_size_max,
				"color": steam_soft_color, "fade": 0.4, "radius": 0.14,
				"material": "soft",
			}]
		"steam_puff":
			return [{
				"id": "steam_puff",
				"amount": maxi(int(steam_amount * 0.7), 4), "lifetime": steam_lifetime * 0.7,
				"explosiveness": 0.7, "preprocess": 0.18,
				"direction": Vector3.UP, "spread": steam_spread + 10.0,
				"speed_min": steam_speed_min * 1.4, "speed_max": steam_speed_max * 1.4,
				"gravity": Vector3(0.0, steam_rise, 0.0),
				"size_min": steam_size_min, "size_max": steam_size_max,
				"color": steam_color, "fade": 0.2, "radius": 0.12,
				"material": "soft",
			}]
		"wash":
			return [{
				"id": "suds",
				"amount": suds_amount, "lifetime": suds_lifetime, "one_shot": false,
				"preprocess": suds_lifetime * 0.6, "randomness": 0.6,
				"direction": Vector3.UP, "spread": 20.0,
				"speed_min": 0.12, "speed_max": 0.4,
				"gravity": Vector3(0.0, 0.12, 0.0),
				"size_min": suds_size_min, "size_max": suds_size_max,
				"color": suds_color, "fade": 0.35, "radius": 0.11,
				"angle_min": 0.0, "angle_max": 360.0,
				"material": "soft",
			}, {
				"id": "droplets",
				"amount": maxi(suds_amount / 2, 3), "lifetime": 0.5, "one_shot": false,
				"preprocess": 0.3, "randomness": 0.7,
				"direction": Vector3.UP, "spread": 45.0,
				"speed_min": 0.6, "speed_max": 1.3,
				"gravity": Vector3(0.0, -3.0, 0.0),
				"size_min": splash_size_min, "size_max": splash_size_max,
				"color": splash_color, "fade": 0.3, "radius": 0.1,
				"angle_min": 0.0, "angle_max": 360.0,
				"material": "soft",
			}]
		"splash":
			return [{
				"id": "splash",
				"amount": splash_amount, "lifetime": splash_lifetime,
				"explosiveness": 1.0, "preprocess": 0.12,
				"direction": Vector3.UP, "spread": 55.0,
				"speed_min": splash_speed_min, "speed_max": splash_speed_max,
				"gravity": Vector3(0.0, -3.5, 0.0),
				"size_min": splash_size_min, "size_max": splash_size_max,
				"color": splash_color, "fade": 0.25, "radius": 0.12,
				"angle_min": 0.0, "angle_max": 360.0,
				"material": "soft",
			}]
		"sparkle":
			return [{
				"id": "sparkle",
				"amount": maxi(int(sparkle_amount * scale), 4), "lifetime": sparkle_lifetime,
				"explosiveness": 1.0, "preprocess": 0.1,
				"direction": Vector3.UP, "spread": 180.0,
				"speed_min": sparkle_speed_min, "speed_max": sparkle_speed_max,
				"gravity": Vector3(0.0, -1.5, 0.0),
				"size_min": sparkle_size_min, "size_max": sparkle_size_max,
				"color": sparkle_color, "fade": 0.15, "radius": 0.06,
				"angle_min": 0.0, "angle_max": 360.0,
				"spin_min": -180.0, "spin_max": 180.0,
				"material": "soft",
			}]
		"dust":
			return [{
				"id": "dust",
				"amount": maxi(int(dust_amount * scale), 3), "lifetime": dust_lifetime,
				"explosiveness": 0.8, "preprocess": 0.1,
				"direction": Vector3.UP, "spread": 70.0,
				"speed_min": dust_speed_min, "speed_max": dust_speed_max,
				"gravity": Vector3(0.0, -0.6, 0.0),
				"size_min": dust_size_min * scale, "size_max": dust_size_max * scale,
				"color": dust_color, "fade": 0.3, "radius": 0.1,
				"angle_min": 0.0, "angle_max": 360.0,
				"material": "soft",
			}]
		"confetti":
			return [{
				"id": "confetti",
				"amount": confetti_amount, "lifetime": confetti_lifetime,
				"explosiveness": 1.0, "preprocess": 0.15,
				"lifetime_randomness": 0.35,
				"direction": Vector3.UP, "spread": 50.0,
				"speed_min": confetti_speed_min, "speed_max": confetti_speed_max,
				"gravity": Vector3(0.0, -3.0, 0.0),
				"size_min": confetti_size_min, "size_max": confetti_size_max,
				"color": Color.WHITE, "ramp": "confetti", "radius": 0.16,
				"angle_min": 0.0, "angle_max": 360.0,
				"spin_min": -360.0, "spin_max": 360.0,
				"material": "flat",
			}]
		"shards":
			return [{
				"id": "shards",
				"amount": shard_amount, "lifetime": shard_lifetime,
				"explosiveness": 1.0, "preprocess": 0.1,
				"direction": Vector3.UP, "spread": 80.0,
				"speed_min": shard_speed_min, "speed_max": shard_speed_max,
				"gravity": Vector3(0.0, -6.0, 0.0),
				"size_min": shard_size_min, "size_max": shard_size_max,
				"color": shard_color, "fade": 0.3, "radius": 0.12,
				"angle_min": 0.0, "angle_max": 360.0,
				"spin_min": -300.0, "spin_max": 300.0,
				"material": "flat",
			}]
		"ooze":
			return [{
				"id": "ooze",
				"amount": ooze_amount, "lifetime": ooze_lifetime,
				"explosiveness": 1.0, "preprocess": 0.1,
				"direction": Vector3.UP, "spread": 60.0,
				"speed_min": ooze_speed_min, "speed_max": ooze_speed_max,
				"gravity": Vector3(0.0, -2.5, 0.0),
				"size_min": ooze_size_min, "size_max": ooze_size_max,
				"color": ooze_color, "fade": 0.25, "radius": 0.16,
				"angle_min": 0.0, "angle_max": 360.0,
				"material": "soft",
			}]
	return []


# ---------------------------------------------------------------------------
# Particle materials and meshes (built in code, shared by every emitter)
# ---------------------------------------------------------------------------

func _build_shared_resources() -> void:
	_particle_mesh = QuadMesh.new()
	_particle_mesh.size = Vector2.ONE

	_soft_material = _base_particle_material()
	_soft_material.albedo_texture = _make_puff_texture(64)

	_flat_material = _base_particle_material()


## Unshaded, alpha-blended, camera-facing quads that take their colour (and
## fade) from the particle's vertex colour.
func _base_particle_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.disable_receive_shadows = true
	return mat


## Soft round puff, generated at runtime (no texture asset exists for this).
func _make_puff_texture(size: int) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var centre := Vector2(float(size) * 0.5, float(size) * 0.5)
	var radius := float(size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(float(x) + 0.5, float(y) + 0.5).distance_to(centre) / radius
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


func _process_material(cfg: Dictionary) -> ParticleProcessMaterial:
	var id: String = str(cfg.get("id", "default"))
	if _materials.has(id):
		return _materials[id]
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = float(cfg.get("radius", 0.05))
	pm.direction = cfg.get("direction", Vector3.UP)
	pm.spread = float(cfg.get("spread", 30.0))
	pm.initial_velocity_min = float(cfg.get("speed_min", 0.3))
	pm.initial_velocity_max = float(cfg.get("speed_max", 0.8))
	pm.gravity = cfg.get("gravity", Vector3.ZERO)
	pm.scale_min = float(cfg.get("size_min", 0.1))
	pm.scale_max = float(cfg.get("size_max", 0.3))
	pm.angle_min = float(cfg.get("angle_min", 0.0))
	pm.angle_max = float(cfg.get("angle_max", 0.0))
	pm.angular_velocity_min = float(cfg.get("spin_min", 0.0))
	pm.angular_velocity_max = float(cfg.get("spin_max", 0.0))
	pm.damping_min = float(cfg.get("damping_min", 0.0))
	pm.damping_max = float(cfg.get("damping_max", 0.0))
	pm.lifetime_randomness = float(cfg.get("lifetime_randomness", 0.0))
	var color: Color = cfg.get("color", Color.WHITE)
	pm.color = color
	if cfg.get("ramp", "") == "confetti":
		pm.color_ramp = _confetti_ramp()
	else:
		pm.color_ramp = _fade_ramp(color, float(cfg.get("fade", 0.3)))
	_materials[id] = pm
	return pm


## Colour over a particle's life: hold, then fade to nothing.
func _fade_ramp(color: Color, fade_start: float) -> GradientTexture1D:
	var offsets := PackedFloat32Array([0.0, clampf(fade_start, 0.05, 0.9), 1.0])
	var colors := PackedColorArray([
		Color(color.r, color.g, color.b, color.a * 0.85),
		Color(color.r, color.g, color.b, color.a),
		Color(color.r, color.g, color.b, 0.0),
	])
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors
	var tex := GradientTexture1D.new()
	tex.gradient = gradient
	tex.width = 32
	return tex


## Hard colour steps, so particles at different life phases read as a mix of
## colours (the closest thing to multi-coloured confetti without textures).
func _confetti_ramp() -> GradientTexture1D:
	var offsets := PackedFloat32Array([0.0, 0.2, 0.25, 0.45, 0.5, 0.7, 0.75, 1.0])
	var colors := PackedColorArray([
		Color(1.0, 0.35, 0.35), Color(1.0, 0.35, 0.35),
		Color(1.0, 0.9, 0.35), Color(1.0, 0.9, 0.35),
		Color(0.4, 0.7, 1.0), Color(0.4, 0.7, 1.0),
		Color(0.45, 0.95, 0.5), Color(0.45, 0.95, 0.5, 0.0),
	])
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors
	var tex := GradientTexture1D.new()
	tex.gradient = gradient
	tex.width = 32
	return tex


# ---------------------------------------------------------------------------
# Rings and floating labels (also pooled, animated on the real-time clock)
# ---------------------------------------------------------------------------

func _ring(pos: Vector3, color: Color, scale := 1.0) -> void:
	var node := _acquire_ring()
	if node == null:
		return
	node.global_position = pos
	node.scale = Vector3.ONE * (ring_start_scale * scale)
	node.visible = true
	var mat := node.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(color.r, color.g, color.b, ring_alpha)
	_ring_age[node] = 0.0
	_ring_scale[node] = scale
	_active_rings.append(node)
	_bump(stats, "ring")


func _acquire_ring() -> MeshInstance3D:
	var node: MeshInstance3D = null
	if not _free_rings.is_empty():
		node = _free_rings.pop_back()
	elif _active_rings.size() + _free_rings.size() < ring_pool_size:
		node = MeshInstance3D.new()
		node.name = "FxRing"
		var torus := TorusMesh.new()
		torus.inner_radius = 0.34
		torus.outer_radius = 0.5
		node.mesh = torus
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(1.0, 1.0, 1.0, ring_alpha)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		node.material_override = mat
		node.visible = false
		add_child(node)
	if node == null:
		return null
	return node


func _money_label(pos: Vector3, amount: int) -> void:
	var node := _acquire_label()
	if node == null:
		return
	node.text = "+$%d" % amount
	node.global_position = pos
	node.scale = Vector3.ONE * 0.55
	node.visible = true
	node.modulate = Color(money_label_color.r, money_label_color.g, money_label_color.b, 1.0)
	_label_base_y[node] = pos.y
	_label_age[node] = 0.0
	_active_labels.append(node)
	_bump(stats, "money_label")


func _acquire_label() -> Label3D:
	var node: Label3D = null
	if not _free_labels.is_empty():
		node = _free_labels.pop_back()
	elif _active_labels.size() + _free_labels.size() < label_pool_size:
		node = Label3D.new()
		node.name = "FxMoneyLabel"
		node.font_size = 64
		node.outline_size = 14
		node.outline_modulate = Color(0.05, 0.12, 0.05, 0.9)
		node.pixel_size = money_label_size
		node.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		node.no_depth_test = true
		node.double_sided = true
		node.visible = false
		add_child(node)
	if node == null:
		return null
	return node


func _process(delta: float) -> void:
	# Early out: with nothing alive this is a single comparison per frame.
	if _live_particles.is_empty() and _active_rings.is_empty() and _active_labels.is_empty():
		return
	var now := float(Time.get_ticks_msec())
	var i := _live_particles.size() - 1
	while i >= 0:
		var node := _live_particles[i]
		if now >= float(_expires.get(node, 0.0)):
			_release_particle(node)
		i -= 1
	_animate_rings(delta)
	_animate_labels(delta)


func _animate_rings(delta: float) -> void:
	var i := _active_rings.size() - 1
	while i >= 0:
		var node := _active_rings[i]
		var age := float(_ring_age.get(node, 0.0)) + delta
		_ring_age[node] = age
		var t := clampf(age / maxf(ring_lifetime, 0.01), 0.0, 1.0)
		var span := float(_ring_scale.get(node, 1.0))
		node.scale = Vector3.ONE * lerpf(ring_start_scale, ring_end_scale, t) * span
		var mat := node.material_override as StandardMaterial3D
		if mat != null:
			var c := mat.albedo_color
			c.a = ring_alpha * (1.0 - t)
			mat.albedo_color = c
		if t >= 1.0:
			node.visible = false
			_active_rings.remove_at(i)
			_ring_age.erase(node)
			_ring_scale.erase(node)
			_free_rings.append(node)
		i -= 1


func _animate_labels(delta: float) -> void:
	var i := _active_labels.size() - 1
	while i >= 0:
		var node := _active_labels[i]
		var age := float(_label_age.get(node, 0.0)) + delta
		_label_age[node] = age
		var t := clampf(age / maxf(money_label_lifetime, 0.01), 0.0, 1.0)
		node.position.y = float(_label_base_y.get(node, 0.0)) + money_label_rise * t
		node.scale = Vector3.ONE * lerpf(0.55, 1.0, clampf(age / 0.18, 0.0, 1.0))
		var alpha := 1.0 - smoothstep(0.55, 1.0, t)
		node.modulate = Color(money_label_color.r, money_label_color.g, money_label_color.b, alpha)
		if t >= 1.0:
			node.visible = false
			_active_labels.remove_at(i)
			_label_age.erase(node)
			_free_labels.append(node)
		i -= 1


# ---------------------------------------------------------------------------
# Positions (read from the kitchen; never written back)
# ---------------------------------------------------------------------------

## World position of a cell's surface (where items sit).
func _cell_top(cell: Vector2i) -> Vector3:
	if kitchen == null:
		return Vector3(float(cell.x), 0.05, float(cell.y))
	return kitchen.cell_to_world(cell) + Vector3(0.0, kitchen.surface_height(cell), 0.0)


## Middle of a station's footprint, on its surface.
func _station_top(station: StationInstance) -> Vector3:
	if kitchen == null or station == null:
		return Vector3.ZERO
	var sum := Vector3.ZERO
	var count := 0
	for cell in station.cells:
		sum += kitchen.cell_to_world(cell)
		count += 1
	if count == 0:
		return Vector3.ZERO
	var centre := sum / float(count)
	centre.y = kitchen.surface_height(station.origin())
	return centre


## World position of a wall edge (the middle of the edge, at wall height). The
## burst is nudged into the room the wall belongs to, so the shards are not half
## buried in the wall itself.
func _edge_world(edge: Vector3i) -> Vector3:
	var pos := Vector3(float(edge.x), 0.0, float(edge.y))
	if edge.z == KitchenLayout.DIR_X:
		pos.x += 0.5
	else:
		pos.z += 0.5
	if kitchen != null:
		for cell in KitchenLayout.edge_cells(edge):
			if kitchen.has_floor(cell):
				var inside := kitchen.cell_to_world(cell)
				# well into the room: the kit's walls are thick enough to swallow
				# a burst spawned on the wall plane itself
				pos.x = lerpf(pos.x, inside.x, 0.9)
				pos.z = lerpf(pos.z, inside.z, 0.9)
				break
	return pos + Vector3(0.0, shard_height, 0.0)
