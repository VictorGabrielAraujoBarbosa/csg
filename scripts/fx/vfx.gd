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
##   [signal Service.work_started]   cooking job  -> steam wisps + a live flame
##                                                  and heat shimmer over the stove
##                                   washing job  -> suds + droplets at the sink
##   [signal Service.work_finished]  any recipe   -> sparkle burst (small for take_*)
##                                   dishes       -> expanding ring (+ splash / steam puff)
##   [signal Service.item_dropped]   item lands   -> small dust puff
##   [signal Service.item_carried]   item lifted  -> glow that bobs along in the hands
##   [signal Service.order_delivered] order done  -> confetti + ring + floating "+$25"
##                                                  + a "SERVED" stamp
##   [signal Service.window_broken]  a window is smashed -> glass shard burst
##   [signal Service.worker_consumed] a worker is eaten -> green ooze puff
##   [signal Service.mob_started]    the mob is in -> red ambient/sun flicker
##   [signal Service.mob_finished]   the mob is gone -> the original light is restored
##   [signal Kitchen.layout_edited]  piece placed -> dust puff under the piece
##   [signal ItemManager.item_removed] consumed   -> tiny dust puff
##
## Two effects are polled instead of driven by a signal, because the simulation
## has no event for them: a fleeing worker raises a "!" bubble
## ([enum Worker.State] FLEE) and the placement hover gets a soft decal while the
## [PlaceController] reports a hover (build phase only). Both are read-only.

@export var service_path: NodePath
@export var kitchen_path: NodePath
## The [AudioBank] this layer drives (every effect has a sound twin).
@export var audio_path: NodePath
## The [PlaceController] whose hover the placement decal follows. Found next to
## this node when empty; the decal only appears while it reports a hover.
@export var placer_path: NodePath

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
## "SERVED" stamps alive at once (their own pool: they animate differently).
@export var stamp_pool_size := 3
## "!" bubbles alive at once (one per panicking worker).
@export var bubble_pool_size := 4
## Glows riding in workers' hands at once (one per carried item).
@export var carry_pool_size := 4
## Lamps the stove flame can throw at once (one per cooking station).
@export var fire_light_pool_size := 4
## Floor decals the placement hover can light up (a 5x3 table needs 15).
@export var hover_decal_pool_size := 16

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

@export_group("Fire (cooking stove)")
## Flame licks alive at once while a `cooking` station runs (the stove).
@export var fire_amount := 14
@export var fire_lifetime := 0.5
@export var fire_speed_min := 0.35
@export var fire_speed_max := 0.95
@export var fire_spread := 14.0
@export var fire_size_min := 0.1
@export var fire_size_max := 0.26
## Saturated orange with real alpha: the kitchen is bright and white, so a pale
## flame would wash out — the colour ramp carries the fire from yellow to red.
@export var fire_color := Color(1.0, 0.55, 0.15, 0.95)
## Height above the station surface where the flame starts (the burner).
@export var fire_height := 0.05
## The whole flame breathes at this rate so it is *animated* fire, not a decal.
@export var fire_flicker_speed := 16.0
@export_range(0.0, 1.0, 0.01) var fire_flicker_amount := 0.16
## Faint heat shimmer rising over the flame: big, slow, almost transparent.
@export var shimmer_amount := 5
@export var shimmer_lifetime := 1.2
@export var shimmer_size_min := 0.2
@export var shimmer_size_max := 0.45
@export var shimmer_color := Color(1.0, 0.72, 0.42, 0.14)
@export var shimmer_height := 0.32
## Small light the flame throws on the stove (0 = no lamp is pooled at all).
@export var fire_light_energy := 1.0
@export var fire_light_range := 2.2
@export var fire_light_color := Color(1.0, 0.6, 0.25)
## Per-frame energy jitter on top of the flicker (0 = a smooth pulse).
@export_range(0.0, 1.0, 0.01) var fire_light_flicker := 0.35

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
## While the mob is inside, the room's ambient and sun energy pulse down (and the
## suns wash red). The originals are remembered and put back when it ends.
@export var horror_flicker_enabled := true
@export_range(0.0, 1.0, 0.01) var horror_ambient_scale := 0.5
@export_range(0.0, 1.0, 0.01) var horror_sun_scale := 0.5
@export var horror_flicker_speed := 9.0
## Random per-frame dip on top of the sine pulse (0 = a clean heartbeat).
@export_range(0.0, 1.0, 0.01) var horror_flicker_jitter := 0.4
@export var horror_light_tint := Color(1.0, 0.42, 0.34)
@export_range(0.0, 1.0, 0.01) var horror_tint_mix := 0.8

@export_group("Panic bubble (fleeing workers)")
## How long one "!" bubble is shown, and how high above the worker it floats.
@export var bubble_lifetime := 1.3
@export var bubble_height := 1.0
@export var bubble_rise := 0.3
## How tall the bubble is in metres, and how long its pop-in takes.
@export var bubble_size := 0.6
@export var bubble_pop_time := 0.16
## The "!" glyph; the bubble itself is white with a dark rim.
@export var bubble_mark_color := Color(0.82, 0.12, 0.1)
## Seconds before the same worker raises another bubble: fleeing re-plans every
## few ticks, so without this a panicking worker would machine-gun bubbles.
@export var bubble_cooldown := 3.0

@export_group("Carried item highlight")
## Soft glow that rides along with the item in a worker's hands, bobbing gently
## so "this is being carried" reads even with the chibi's back turned.
@export var carry_glow_color := Color(1.0, 0.95, 0.7, 0.45)
@export var carry_glow_size := 0.55
@export var carry_bob_height := 0.025
@export var carry_bob_speed := 7.0
@export_range(0.0, 1.0, 0.01) var carry_pulse := 0.12

@export_group("Served stamp")
@export var stamp_lifetime := 1.0
@export var stamp_text := "SERVED"
## Stamps land big and shrink onto the delivery point, then fade.
@export var stamp_start_scale := 2.6
@export var stamp_end_scale := 1.0
## Seconds the landing takes (the rest of the life is the hold + fade).
@export var stamp_land_time := 0.22
## Fraction of the life at which the fade starts.
@export_range(0.1, 1.0, 0.05) var stamp_hold := 0.55
@export var stamp_height := 1.35
@export var stamp_rise := 0.3
@export var stamp_size := 0.009
@export var stamp_color := Color(0.6, 1.0, 0.62)
@export var stamp_outline := Color(0.03, 0.14, 0.05, 0.95)

@export_group("Placement hover")
## Soft decal under the piece the placer is hovering (build phase only). Valid
## spots pulse green and invalid ones red — the same signal the placer's own
## ghost carries, but on a decal of ours: the ghost's materials are the placer's.
@export var hover_glow_enabled := true
@export var hover_glow_size := 1.25
@export var hover_glow_valid_color := Color(0.4, 1.0, 0.5)
@export var hover_glow_invalid_color := Color(1.0, 0.4, 0.35)
@export_range(0.0, 1.0, 0.01) var hover_glow_alpha := 0.7
@export var hover_glow_pulse_speed := 3.2
@export_range(0.0, 1.0, 0.01) var hover_glow_pulse := 0.3
## How quickly the decals catch up with the cursor, and how high they sit.
@export var hover_glow_follow := 14.0
@export var hover_glow_height := 0.02

var service: Service
var kitchen: Kitchen
var audio: AudioBank
## The placement controller the hover decal follows (read-only: its hover cell,
## validity and rotation are read, never written).
var placer: PlaceController

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
var _loop_kind: Dictionary = {}  # key -> effect name ("steam", "fire", "wash", ...)
var _loop_owner: Dictionary = {} # key -> Worker, for loops that die with their worker
var _loop_phase: Dictionary = {} # key -> float (real-time flicker phase)
var _loop_lights: Dictionary = {}# key -> OmniLight3D (the flame's lamp)

var _free_lights: Array[OmniLight3D] = []
var _live_lights: Array[OmniLight3D] = []

var _free_rings: Array[MeshInstance3D] = []
var _active_rings: Array[MeshInstance3D] = []
var _ring_age: Dictionary = {}
var _ring_scale: Dictionary = {}
var _free_labels: Array[Label3D] = []
var _active_labels: Array[Label3D] = []
var _label_age: Dictionary = {}
var _label_base_y: Dictionary = {}

var _free_stamps: Array[Label3D] = []
var _active_stamps: Array[Label3D] = []
var _stamp_age: Dictionary = {}
var _stamp_base_y: Dictionary = {}

var _free_bubbles: Array[PanicBubble] = []
var _active_bubbles: Array[PanicBubble] = []
var _bubble_age: Dictionary = {}
var _bubble_base_y: Dictionary = {}
var _bubble_owner: Dictionary = {}  # PanicBubble -> Worker it floats over
## Worker instance id -> msec when it last raised a bubble (cooldown guard).
var _flee_shown: Dictionary = {}

var _free_carry: Array[MeshInstance3D] = []
var _active_carry: Array[MeshInstance3D] = []
var _carry_item: Dictionary = {}    # MeshInstance3D -> WorldItem
var _carry_worker: Dictionary = {}  # MeshInstance3D -> Worker
var _carry_age: Dictionary = {}

var _hover_decals: Array[MeshInstance3D] = []
var _hover_cells: Array[Vector2i] = []
var _hover_valid := false
var _hover_fade := 0.0
var _hover_time := 0.0
var _hover_shown := false

## Horror light: the originals are remembered the first time the mob starts and
## restored when it is over, so the look is never left altered.
var _horror_on := false
var _horror_time := 0.0
var _ambient_env: Environment = null
var _ambient_energy := 0.0
var _ambient_color := Color.WHITE
var _ambient_sky := 0.0
var _light_restore: Array[Dictionary] = []

var _furniture_seen: Dictionary = {}
var _items_connected := false


## A pooled "!" bubble: a white disc (with a tail) and the mark on top of it.
class PanicBubble extends Node3D:
	var disc: MeshInstance3D
	var disc_material: StandardMaterial3D
	var mark: Label3D


func _ready() -> void:
	service = _resolve_node(service_path, "Service") as Service
	kitchen = _resolve_node(kitchen_path, "Kitchen") as Kitchen
	audio = _resolve_node(audio_path, "AudioBank") as AudioBank
	placer = _resolve_node(placer_path, "PlaceController") as PlaceController
	_build_shared_resources()
	if service != null:
		service.work_started.connect(_on_work_started)
		service.work_finished.connect(_on_work_finished)
		service.item_carried.connect(_on_item_carried)
		service.item_dropped.connect(_on_item_dropped)
		service.order_delivered.connect(_on_order_delivered)
		service.window_broken.connect(_on_window_broken)
		service.worker_consumed.connect(_on_worker_consumed)
		service.mob_started.connect(_on_mob_started)
		service.mob_finished.connect(_on_mob_finished)
		service.tick_passed.connect(_on_tick)
		_try_connect_items()
	if kitchen != null:
		kitchen.layout_rebuilt.connect(_snapshot_furniture)
		kitchen.layout_edited.connect(_on_layout_edited)
		_snapshot_furniture()


func _exit_tree() -> void:
	# Never leave the world dimmed if we are torn down mid-horror.
	if _horror_on:
		_stop_horror()
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
## the stations that need them (steam + flame for cooking, suds for washing).
func _on_work_started(worker: Worker, job: Job) -> void:
	if job == null or job.recipe == null or job.station == null:
		return
	var top := _station_top(job.station)
	if audio != null:
		audio.play_work_start(job.recipe.id, top)
	if job.station.has_tag(&"cooking"):
		_start_loop(_worker_key(worker, "steam"), "steam", top + Vector3(0.0, steam_height, 0.0), worker)
		# The stove gets real fire: a flame licking off the burner, its own light
		# and a faint heat shimmer above it, all on the same start/stop seam as
		# the steam (both die when the job ends or the worker walks off).
		_start_loop(_worker_key(worker, "fire"), "fire", top + Vector3(0.0, fire_height, 0.0), worker)
		_start_loop(_worker_key(worker, "shimmer"), "fire_shimmer",
			top + Vector3(0.0, shimmer_height, 0.0), worker)
	elif job.station.has_tag(&"washing"):
		_start_loop(_worker_key(worker, "wash"), "wash", top + Vector3(0.0, 0.12, 0.0), worker)


## The work finished and its outputs were spawned: stop the loop, then burst at
## the station's output cell.
func _on_work_finished(worker: Worker, job: Job) -> void:
	if worker != null:
		_stop_worker_loops(worker)
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


## A worker lifted an item: a soft glow starts riding along with it.
func _on_item_carried(item: WorldItem, worker: Worker) -> void:
	if audio != null and worker != null:
		audio.play_pickup(worker.global_position + Vector3(0.0, 0.5, 0.0))
	if item != null and worker != null:
		_start_carry_glow(item, worker)


## A carried item landed: a small dust puff where it hit the surface.
func _on_item_dropped(item: WorldItem, cell: Vector2i) -> void:
	_burst("dust", _cell_top(cell) + Vector3(0.0, 0.04, 0.0), 1.2, "dust_drop")
	if item != null:
		_stop_carry_glow(item)
	if audio != null and item != null:
		audio.play_drop(item.def.id, _cell_top(cell))


## The order left the kitchen: confetti, a ring, the floating payout and the
## "SERVED" stamp landing over the delivery point.
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
	_served_stamp(pos + Vector3(0.0, stamp_height, 0.0))
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
## cancelled job does not leave steam (or a lit stove) running forever.
func _on_tick(_tick: int) -> void:
	_try_connect_items()
	if _loop_owner.is_empty():
		return
	var stale: Array = []
	for key in _loop_owner.keys():
		var worker: Worker = _loop_owner[key]
		if not is_instance_valid(worker) or worker.state != Worker.State.WORK or worker.job == null:
			stale.append(key)
	for key in stale:
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


## Starts a looping effect by name ("steam", "fire", "wash") at a world position,
## keyed so it can be stopped again (pass a Worker as the key to have it stop
## automatically when that worker leaves the station).
func start_loop(kind: String, position: Vector3, key: Variant = "manual") -> void:
	_start_loop(key, kind, position, key if key is Worker else null)


func stop_loop(key: Variant = "manual") -> void:
	_stop_loop(key)


func live_particle_count() -> int:
	return _live_particles.size()


func pooled_particle_count() -> int:
	return _live_particles.size() + _free_particles.size()


## Station loops running right now (steam / flame / shimmer / suds): a test can
## assert this is 0 when the kitchen goes quiet, i.e. nothing was left burning.
func loop_count() -> int:
	return _loops.size()


## Flame lamps burning right now (they are released with their loop).
func light_count() -> int:
	return _live_lights.size()


## Dev tool / test helper: what is looping right now, with the numbers that
## matter when an effect renders wrong (position, size, colour, light).
func describe_loops() -> Array[String]:
	var out: Array[String] = []
	for key in _loops.keys():
		var nodes: Array = _loops[key]
		for node: GPUParticles3D in nodes:
			var cfg_mat := node.process_material as ParticleProcessMaterial
			out.append("loop %s kind=%s pos=%s amount=%d emitting=%s visible=%s scale=%s lifetime=%.2f size=%.3f..%.3f color=%s" % [
				str(key), str(_loop_kind.get(key, "?")), node.global_position, node.amount,
				node.emitting, node.visible, node.scale, node.lifetime,
				cfg_mat.scale_min if cfg_mat != null else -1.0,
				cfg_mat.scale_max if cfg_mat != null else -1.0,
				cfg_mat.color if cfg_mat != null else Color.BLACK])
		var light: Variant = _loop_lights.get(key)
		if light is OmniLight3D:
			out.append("  light at %s energy=%.2f range=%.2f color=%s" % [
				(light as OmniLight3D).global_position, (light as OmniLight3D).light_energy,
				(light as OmniLight3D).omni_range, (light as OmniLight3D).light_color])
	return out


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


# ---------------------------------------------------------------------------
# Flame lamps (the stove light: pooled like everything else)
# ---------------------------------------------------------------------------

func _acquire_light(kind: String) -> OmniLight3D:
	if kind != "fire" or fire_light_energy <= 0.0:
		return null
	var light: OmniLight3D = null
	if not _free_lights.is_empty():
		light = _free_lights.pop_back()
	elif _live_lights.size() < fire_light_pool_size:
		light = OmniLight3D.new()
		light.name = "FxFlameLight"
		light.shadow_enabled = false
		light.visible = false
		add_child(light)
	if light == null:
		return null
	light.light_color = fire_light_color
	light.omni_range = fire_light_range
	light.light_energy = fire_light_energy
	light.visible = true
	_live_lights.append(light)
	return light


func _release_light(light: OmniLight3D) -> void:
	light.visible = false
	var index := _live_lights.find(light)
	if index >= 0:
		_live_lights.remove_at(index)
	if not _free_lights.has(light):
		_free_lights.append(light)


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


## Starts (or restarts) a loop under [param key]: the emitters of one effect
## recipe, plus the lamp the flame needs. [param owner] is the worker the loop
## dies with (checked every tick), or null for a manually keyed loop.
func _start_loop(key: Variant, kind: String, pos: Vector3, owner: Variant = null) -> void:
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
	_loop_kind[key] = kind
	_loop_phase[key] = randf() * TAU
	if owner is Worker:
		_loop_owner[key] = owner
	var light := _acquire_light(kind)
	if light != null:
		light.global_position = pos + Vector3(0.0, 0.06, 0.0)
		_loop_lights[key] = light
	_bump(stats, kind)


func _stop_loop(key: Variant) -> void:
	_loop_kind.erase(key)
	_loop_owner.erase(key)
	_loop_phase.erase(key)
	var light: Variant = _loop_lights.get(key)
	if light is OmniLight3D:
		_release_light(light as OmniLight3D)
	_loop_lights.erase(key)
	if not _loops.has(key):
		return
	var nodes: Array = _loops[key]
	_loops.erase(key)
	var now := float(Time.get_ticks_msec())
	for node: GPUParticles3D in nodes:
		node.emitting = false
		_expires[node] = now + (node.lifetime + pool_margin) * 1000.0


## Every loop that belongs to [param worker] (steam, flame, shimmer, suds).
func _stop_worker_loops(worker: Worker) -> void:
	if worker == null:
		return
	var keys: Array = []
	for key in _loop_owner.keys():
		if _loop_owner[key] == worker:
			keys.append(key)
	for key in keys:
		_stop_loop(key)


## Loop keys are strings, so one worker can run several effects at once.
func _worker_key(worker: Worker, kind: String) -> String:
	if worker == null:
		return "manual:" + kind
	return "w%d:%s" % [worker.get_instance_id(), kind]


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
		"fire":
			return [{
				"id": "fire",
				"amount": fire_amount, "lifetime": fire_lifetime, "one_shot": false,
				"preprocess": fire_lifetime * 0.7, "randomness": 0.5,
				"direction": Vector3.UP, "spread": fire_spread,
				"speed_min": fire_speed_min, "speed_max": fire_speed_max,
				"gravity": Vector3(0.0, 0.25, 0.0),
				"size_min": fire_size_min, "size_max": fire_size_max,
				"color": fire_color, "ramp": "flame", "radius": 0.05,
				"angle_min": 0.0, "angle_max": 360.0,
				"spin_min": -60.0, "spin_max": 60.0,
				"material": "soft",
			}]
		"fire_shimmer":
			return [{
				"id": "fire_shimmer",
				"amount": shimmer_amount, "lifetime": shimmer_lifetime, "one_shot": false,
				"preprocess": shimmer_lifetime * 0.8, "randomness": 0.6,
				"direction": Vector3.UP, "spread": fire_spread + 18.0,
				"speed_min": fire_speed_min * 0.6, "speed_max": fire_speed_max * 0.6,
				"gravity": Vector3(0.0, 0.3, 0.0),
				"size_min": shimmer_size_min, "size_max": shimmer_size_max,
				"color": shimmer_color, "fade": 0.15, "radius": 0.1,
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
	var ramp: String = str(cfg.get("ramp", ""))
	if ramp == "confetti":
		pm.color_ramp = _confetti_ramp()
	elif ramp == "flame":
		pm.color_ramp = _flame_ramp()
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


## A flame is a colour *over time*: hot yellow at birth, orange as it rises, red
## before it goes. The saturated end matters — the kitchen behind is white.
func _flame_ramp() -> GradientTexture1D:
	var offsets := PackedFloat32Array([0.0, 0.22, 0.55, 1.0])
	var colors := PackedColorArray([
		Color(1.0, 0.95, 0.62, 0.95),
		Color(1.0, 0.62, 0.18, 0.92),
		Color(0.95, 0.32, 0.08, 0.6),
		Color(0.7, 0.18, 0.05, 0.0),
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


# ---------------------------------------------------------------------------
# Served stamps, panic bubbles, carried glows, placement decals
# ---------------------------------------------------------------------------

## The order landed: a big "SERVED" stamp scales onto the delivery point, holds
## for a beat and fades out (on top of the confetti the delivery already fires).
func _served_stamp(pos: Vector3) -> void:
	var node := _acquire_stamp()
	if node == null:
		return
	node.text = stamp_text
	node.global_position = pos
	node.scale = Vector3.ONE * stamp_start_scale
	node.visible = true
	node.modulate = Color(stamp_color.r, stamp_color.g, stamp_color.b, 1.0)
	node.outline_modulate = stamp_outline
	node.pixel_size = stamp_size
	_stamp_base_y[node] = pos.y
	_stamp_age[node] = 0.0
	_active_stamps.append(node)
	_bump(stats, "served_stamp")


func _acquire_stamp() -> Label3D:
	var node: Label3D = null
	if not _free_stamps.is_empty():
		node = _free_stamps.pop_back()
	elif _active_stamps.size() + _free_stamps.size() < stamp_pool_size:
		node = Label3D.new()
		node.name = "FxServedStamp"
		node.font_size = 64
		node.outline_size = 16
		node.outline_modulate = stamp_outline
		node.pixel_size = stamp_size
		node.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		node.no_depth_test = true
		node.double_sided = true
		node.render_priority = 4
		node.visible = false
		add_child(node)
	if node == null:
		return null
	return node


func _animate_stamps(delta: float) -> void:
	var i := _active_stamps.size() - 1
	while i >= 0:
		var node := _active_stamps[i]
		var age := float(_stamp_age.get(node, 0.0)) + delta
		_stamp_age[node] = age
		var t := clampf(age / maxf(stamp_lifetime, 0.01), 0.0, 1.0)
		# land: shrink hard onto the point, then hold, then fade
		var land := 1.0 - pow(1.0 - clampf(age / maxf(stamp_land_time, 0.01), 0.0, 1.0), 3.0)
		node.scale = Vector3.ONE * lerpf(stamp_start_scale, stamp_end_scale, land)
		node.position.y = float(_stamp_base_y.get(node, 0.0)) + stamp_rise * t
		var alpha := 1.0 - smoothstep(stamp_hold, 1.0, t)
		node.modulate = Color(stamp_color.r, stamp_color.g, stamp_color.b, alpha)
		if t >= 1.0:
			node.visible = false
			_active_stamps.remove_at(i)
			_stamp_age.erase(node)
			_stamp_base_y.erase(node)
			_free_stamps.append(node)
		i -= 1


## A panicking worker raises a "!" bubble over its head.
func _panic_bubble(worker: Worker) -> void:
	if worker == null or not is_instance_valid(worker):
		return
	var node := _acquire_bubble()
	if node == null:
		return
	node.global_position = worker.global_position + Vector3(0.0, bubble_height, 0.0)
	node.scale = Vector3.ONE * 0.3
	node.visible = true
	# re-read the tunable on every show, so a live tweak reaches the pooled node
	node.mark.pixel_size = bubble_size * 0.016
	_bubble_owner[node] = worker
	_bubble_base_y[node] = node.global_position.y
	_bubble_age[node] = 0.0
	_active_bubbles.append(node)
	_bump(stats, "panic_bubble")


func _acquire_bubble() -> PanicBubble:
	var node: PanicBubble = null
	if not _free_bubbles.is_empty():
		node = _free_bubbles.pop_back()
	elif _active_bubbles.size() + _free_bubbles.size() < bubble_pool_size:
		node = _new_bubble()
	if node == null:
		return null
	return node


func _new_bubble() -> PanicBubble:
	var node := PanicBubble.new()
	node.name = "FxPanicBubble"
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = _bubble_texture()
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.no_depth_test = true
	mat.render_priority = 3
	node.disc_material = mat
	node.disc = MeshInstance3D.new()
	node.disc.name = "Disc"
	node.disc.mesh = quad
	node.disc.material_override = mat
	node.disc.position = Vector3(0.0, 0.05, 0.0)
	node.add_child(node.disc)
	var mark := Label3D.new()
	mark.name = "Mark"
	mark.text = "!"
	mark.font_size = 64
	mark.outline_size = 0
	mark.pixel_size = bubble_size * 0.016
	mark.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	mark.no_depth_test = true
	mark.double_sided = true
	mark.render_priority = 4
	mark.modulate = bubble_mark_color
	mark.position = Vector3(0.0, 0.07, 0.0)
	node.add_child(mark)
	node.mark = mark
	node.visible = false
	add_child(node)
	return node


## A white speech-bubble disc with a dark rim and a small tail (generated here:
## the project ships no textures for this and no asset may be modified).
func _bubble_texture(size := 64) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var f := float(size)
	var centre := Vector2(f * 0.5, f * 0.42)
	var radius := f * 0.36
	var rim := maxf(f * 0.05, 1.5)
	for y in size:
		for x in size:
			var p := Vector2(float(x) + 0.5, float(y) + 0.5)
			var d := p.distance_to(centre)
			var alpha := 0.0
			var shade := 1.0
			if d <= radius:
				alpha = 1.0
				if d >= radius - rim:
					shade = 0.16
			# the tail: a small wedge pointing down-left out of the disc
			elif p.y > centre.y and p.y < f * 0.98:
				var width := lerpf(f * 0.22, f * 0.06, (p.y - centre.y) / (f * 0.98 - centre.y))
				if absf(p.x - (centre.x - f * 0.16)) <= width * 0.5:
					alpha = 1.0
					shade = 0.16 if width > f * 0.075 else 1.0
			if alpha > 0.0:
				img.set_pixel(x, y, Color(shade, shade, shade, alpha))
	return ImageTexture.create_from_image(img)


## While a worker flees it keeps a bubble up; the cooldown stops a re-planning
## panicker from raising one every few ticks.
func _scan_flee(now: float) -> void:
	if service == null:
		return
	for worker in service.workers:
		if not is_instance_valid(worker) or worker.eaten:
			continue
		if worker.state != Worker.State.FLEE:
			continue
		var id := worker.get_instance_id()
		if now - float(_flee_shown.get(id, -1.0e9)) < bubble_cooldown * 1000.0:
			continue
		_flee_shown[id] = now
		_panic_bubble(worker)


func _animate_bubbles(delta: float) -> void:
	_scan_flee(float(Time.get_ticks_msec()))
	var i := _active_bubbles.size() - 1
	while i >= 0:
		var node := _active_bubbles[i]
		var age := float(_bubble_age.get(node, 0.0)) + delta
		_bubble_age[node] = age
		var owner: Variant = _bubble_owner.get(node)
		if is_instance_valid(owner) and owner is Worker and (owner as Worker).visible:
			var pos := (owner as Worker).global_position
			node.global_position.x = pos.x
			node.global_position.z = pos.z
		var t := clampf(age / maxf(bubble_lifetime, 0.01), 0.0, 1.0)
		node.global_position.y = float(_bubble_base_y.get(node, 0.0)) + bubble_rise * t
		# pop in with a small overshoot, hold, fade
		var pop := clampf(age / maxf(bubble_pop_time, 0.01), 0.0, 1.0)
		node.scale = Vector3.ONE * bubble_size * lerpf(0.35, 1.0, pop) * (1.0 + 0.3 * sin(pop * PI))
		var alpha := 1.0 - smoothstep(0.62, 1.0, t)
		if node.disc_material != null:
			node.disc_material.albedo_color = Color(1.0, 1.0, 1.0, alpha)
		node.mark.modulate = Color(bubble_mark_color.r, bubble_mark_color.g, bubble_mark_color.b, alpha)
		if t >= 1.0:
			node.visible = false
			_active_bubbles.remove_at(i)
			_bubble_age.erase(node)
			_bubble_base_y.erase(node)
			_bubble_owner.erase(node)
			_free_bubbles.append(node)
		i -= 1


## A soft glow starts riding along with the item a worker just picked up.
func _start_carry_glow(item: WorldItem, worker: Worker) -> void:
	if not is_instance_valid(item) or not is_instance_valid(worker):
		return
	_stop_carry_glow(item)
	var node := _acquire_carry()
	if node == null:
		return
	node.visible = true
	node.global_position = item.global_position
	_carry_item[node] = item
	_carry_worker[node] = worker
	_carry_age[node] = 0.0
	_active_carry.append(node)
	_bump(stats, "carry_highlight")


## The item left the worker's hands (dropped, handed over or force-dropped).
func _stop_carry_glow(item: WorldItem) -> void:
	var i := _active_carry.size() - 1
	while i >= 0:
		var node := _active_carry[i]
		if _carry_item.get(node) == item:
			_release_carry(node)
		i -= 1


func _acquire_carry() -> MeshInstance3D:
	var node: MeshInstance3D = null
	if not _free_carry.is_empty():
		node = _free_carry.pop_back()
	elif _active_carry.size() + _free_carry.size() < carry_pool_size:
		node = MeshInstance3D.new()
		node.name = "FxCarryGlow"
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		node.mesh = quad
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_texture = _soft_material.albedo_texture
		mat.albedo_color = carry_glow_color
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mat.billboard_keep_scale = true
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		mat.disable_receive_shadows = true
		node.material_override = mat
		node.visible = false
		add_child(node)
	if node == null:
		return null
	return node


func _release_carry(node: MeshInstance3D) -> void:
	node.visible = false
	var index := _active_carry.find(node)
	if index >= 0:
		_active_carry.remove_at(index)
	_carry_item.erase(node)
	_carry_worker.erase(node)
	_carry_age.erase(node)
	if not _free_carry.has(node):
		_free_carry.append(node)


## The glow follows the item's world position every frame (it never parents
## itself to the worker's hands, so a despawn can never take a pooled node with
## it) and bobs gently so a carried item reads as being carried.
func _animate_carry(delta: float) -> void:
	var i := _active_carry.size() - 1
	while i >= 0:
		var node := _active_carry[i]
		var item: Variant = _carry_item.get(node)
		var worker: Variant = _carry_worker.get(node)
		var held: bool = is_instance_valid(node) and is_instance_valid(item) and is_instance_valid(worker) \
			and (item as WorldItem).get_parent() == (worker as Worker).hands() \
			and (worker as Worker).visible
		if not held:
			_release_carry(node)
			i -= 1
			continue
		var age := float(_carry_age.get(node, 0.0)) + delta
		_carry_age[node] = age
		var bob := sin(age * carry_bob_speed) * carry_bob_height
		node.global_position = (item as WorldItem).global_position + Vector3(0.0, bob, 0.0)
		var pulse := 1.0 + carry_pulse * sin(age * carry_bob_speed * 0.5)
		node.scale = Vector3.ONE * carry_glow_size * pulse
		i -= 1


# ---------------------------------------------------------------------------
# Placement hover decal (build phase; read-only on the placer)
# ---------------------------------------------------------------------------

## Does the placer currently report a hover worth lighting up?
func _hover_wanted() -> bool:
	if not hover_glow_enabled or placer == null or not is_instance_valid(placer):
		return false
	if not placer.enabled or not bool(placer.get("_has_hover")):
		return false
	if placer.current_def() == null and placer.get("_grabbed") == null:
		return false
	return true


## The cells under the hovered piece (the ghost's or the grabbed piece's), and
## whether the spot is valid — the same green/red the placer's ghost shows.
func _hover_target() -> Dictionary:
	if not _hover_wanted():
		return {}
	var def: FurnitureDef = placer.current_def()
	if def == null:
		var grabbed: Variant = placer.get("_grabbed")
		if is_instance_valid(grabbed) and grabbed is FurnitureInstance:
			def = (grabbed as FurnitureInstance).def
	if def == null:
		return {}
	var hover: Variant = placer.get("_hover_cell")
	if not (hover is Vector2i):
		return {}
	var cells: Array[Vector2i] = def.cells(hover, int(placer.get("rot_steps")))
	return {"cells": cells, "valid": bool(placer.get("_valid"))}


func _update_hover(delta: float) -> void:
	_hover_time += delta
	var target := _hover_target()
	var cells: Array[Vector2i] = []
	if not target.is_empty():
		cells = target["cells"]
		_hover_valid = bool(target["valid"])
	var wanted := not cells.is_empty()
	_hover_fade = move_toward(_hover_fade, 1.0 if wanted else 0.0, delta * 6.0)
	if wanted:
		_hover_cells = cells
		if not _hover_shown:
			_hover_shown = true
			_bump(stats, "hover_glow")
	elif _hover_fade <= 0.001:
		_hover_shown = false
	if _hover_cells.is_empty():
		return
	var pulse := 0.5 + 0.5 * sin(_hover_time * hover_glow_pulse_speed)
	var alpha := hover_glow_alpha * _hover_fade * lerpf(1.0 - hover_glow_pulse, 1.0, pulse)
	var color := hover_glow_valid_color if _hover_valid else hover_glow_invalid_color
	for i in _hover_cells.size():
		var decal := _ensure_hover_decal(i)
		if decal == null:
			continue
		var cell := _hover_cells[i]
		var target_pos := _cell_floor(cell)
		if not decal.visible:
			# first frame it shows: land on the cell instead of flying there
			decal.global_position = target_pos
		else:
			var follow := 1.0 - exp(-hover_glow_follow * delta)
			decal.global_position = decal.global_position.lerp(target_pos, follow)
		decal.visible = alpha > 0.005
		var mat := decal.material_override as StandardMaterial3D
		if mat != null:
			mat.albedo_color = Color(color.r, color.g, color.b, alpha)
		decal.scale = Vector3.ONE * hover_glow_size * lerpf(1.0, 1.0 + hover_glow_pulse, pulse)
	for i in range(_hover_cells.size(), _hover_decals.size()):
		_hover_decals[i].visible = false
	if not wanted and _hover_fade <= 0.001:
		_hover_cells = []
		for decal in _hover_decals:
			decal.visible = false


## A soft pulsing outline decal lying flat on the floor under one cell of the
## hovered piece: a glowing rounded rim with a faint fill. One per cell (a 5x3
## table needs 15), created lazily and reused.
func _ensure_hover_decal(index: int) -> MeshInstance3D:
	while _hover_decals.size() <= index and _hover_decals.size() < hover_decal_pool_size:
		var node := MeshInstance3D.new()
		node.name = "FxHoverDecal"
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		node.mesh = quad
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_texture = _decal_texture()
		mat.albedo_color = Color(hover_glow_valid_color.r, hover_glow_valid_color.g, hover_glow_valid_color.b, 0.0)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.disable_receive_shadows = true
		node.material_override = mat
		node.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		node.visible = false
		add_child(node)
		_hover_decals.append(node)
	if index >= _hover_decals.size():
		return null
	return _hover_decals[index]


## The decal's texture: a bright rounded rim with a soft fill, so the pulse
## reads as an outline on the floor rather than a wash of colour.
func _decal_texture(size := 64) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var f := float(size)
	for y in size:
		for x in size:
			var p := Vector2((float(x) + 0.5) / f - 0.5, (float(y) + 0.5) / f - 0.5) * 2.0
			var d := p.length()
			var a := 0.0
			if d <= 0.92:
				a = 0.28 * (1.0 - smoothstep(0.45, 0.92, d))
			if d > 0.7 and d <= 0.94:
				a = maxf(a, 1.0 - absf(d - 0.82) / 0.12)
			if a > 0.0:
				img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


## Dev tool / test helper: the placement decals right now (state + colour), so a
## decal that "exists" but does not show up can be told apart from a missing one.
func describe_hover() -> Array[String]:
	var out: Array[String] = []
	out.append("hover cells=%d fade=%.2f valid=%s wanted=%s decals=%d" % [
		_hover_cells.size(), _hover_fade, _hover_valid, _hover_wanted(), _hover_decals.size()])
	for decal in _hover_decals:
		var mat := decal.material_override as StandardMaterial3D
		out.append("  decal at %s scale=%s visible=%s alpha=%.2f" % [
			decal.global_position, decal.scale, decal.visible,
			mat.albedo_color.a if mat != null else -1.0])
	return out


# ---------------------------------------------------------------------------
# Horror light (ambient + suns; remembered and restored)
# ---------------------------------------------------------------------------

func _on_mob_started(_edges: Array) -> void:
	_start_horror()


func _on_mob_finished() -> void:
	_stop_horror()


## The mob is in: remember what the world looked like and start the flicker.
func _start_horror() -> void:
	if _horror_on or not horror_flicker_enabled:
		return
	_resolve_lights()
	_horror_on = true
	_horror_time = 0.0
	_bump(stats, "horror_flicker")


func _stop_horror() -> void:
	# the cooldown table is per-horror: a new mob means new panic
	_flee_shown.clear()
	if not _horror_on:
		return
	_horror_on = false
	if _ambient_env != null:
		_ambient_env.ambient_light_energy = _ambient_energy
		_ambient_env.ambient_light_color = _ambient_color
		_ambient_env.ambient_light_sky_contribution = _ambient_sky
	for entry in _light_restore:
		var light: Variant = entry.get("node")
		if is_instance_valid(light) and light is DirectionalLight3D:
			(light as DirectionalLight3D).light_energy = float(entry.get("energy", 1.0))
			(light as DirectionalLight3D).light_color = entry.get("color", Color.WHITE)


## Finds the look node and the suns once, at the first horror, and keeps the
## values to put back. Everything here is read from the running scene: the FX
## layer owns neither node and never writes to them outside the horror.
func _resolve_lights() -> void:
	if _ambient_env == null:
		var look := _resolve_node(NodePath(), "WorldEnvironment") as WorldEnvironment
		if look != null and look.environment != null:
			_ambient_env = look.environment
			_ambient_energy = _ambient_env.ambient_light_energy
			_ambient_color = _ambient_env.ambient_light_color
			_ambient_sky = _ambient_env.ambient_light_sky_contribution
	if _light_restore.is_empty():
		for light in _directional_lights():
			_light_restore.append({
				"node": light, "energy": light.light_energy, "color": light.light_color,
			})


func _directional_lights() -> Array[DirectionalLight3D]:
	var out: Array[DirectionalLight3D] = []
	var root := get_tree().current_scene
	if root == null:
		root = get_tree().root
	if root == null:
		return out
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is DirectionalLight3D:
			out.append(node as DirectionalLight3D)
		for child in node.get_children():
			stack.append(child)
	return out


## Pulses the room darker and redder while the mob is inside; the moment the
## service says the attack is over, the originals go back on.
func _update_horror(delta: float) -> void:
	if not _horror_on:
		return
	if service == null or not service.mob_active:
		_stop_horror()
		return
	_horror_time += delta
	var pulse := 0.5 + 0.5 * sin(_horror_time * horror_flicker_speed)
	pulse *= 1.0 - horror_flicker_jitter * randf()
	if _ambient_env != null:
		_ambient_env.ambient_light_energy = _ambient_energy * lerpf(1.0, horror_ambient_scale, pulse)
		# the fill light goes red with it, or the dimming alone just looks grey.
		# The sky's share of the ambient is pulled out at the same time: the room
		# has to be lit by the red, not by daylight through the roof.
		_ambient_env.ambient_light_color = _ambient_color.lerp(horror_light_tint, horror_tint_mix * pulse)
		_ambient_env.ambient_light_sky_contribution = lerpf(_ambient_sky, 0.0, pulse)
	for entry in _light_restore:
		var light: Variant = entry.get("node")
		if not is_instance_valid(light) or not (light is DirectionalLight3D):
			continue
		var sun := light as DirectionalLight3D
		sun.light_energy = float(entry.get("energy", 1.0)) * lerpf(1.0, horror_sun_scale, pulse)
		var base: Color = entry.get("color", Color.WHITE)
		sun.light_color = base.lerp(horror_light_tint, horror_tint_mix * pulse)


# ---------------------------------------------------------------------------
# Per-frame animation (real time only)
# ---------------------------------------------------------------------------

## Is there anything to animate at all? Keeping this cheap is what lets the
## layer sit still for a whole idle build phase.
func _is_idle() -> bool:
	if not _live_particles.is_empty() or not _active_rings.is_empty() \
			or not _active_labels.is_empty() or not _active_stamps.is_empty() \
			or not _active_bubbles.is_empty() or not _active_carry.is_empty() \
			or _horror_on:
		return false
	# a decal that is still fading out has to keep being animated, or it freezes
	# on screen the moment the player drops the selection
	return not _hover_wanted() and _hover_fade <= 0.0


func _process(delta: float) -> void:
	# Early out: with nothing alive this is a few comparisons per frame.
	if _is_idle():
		return
	var now := float(Time.get_ticks_msec())
	var i := _live_particles.size() - 1
	while i >= 0:
		var node := _live_particles[i]
		if now >= float(_expires.get(node, 0.0)):
			_release_particle(node)
		i -= 1
	_animate_loops(delta)
	_animate_rings(delta)
	_animate_labels(delta)
	_animate_stamps(delta)
	_animate_bubbles(delta)
	_animate_carry(delta)
	_update_horror(delta)
	_update_hover(delta)


## The flame is animated, not a static emitter: the whole fire breathes and its
## lamp flickers. Other loops are left alone (steam and suds only age).
func _animate_loops(delta: float) -> void:
	for key in _loop_kind.keys():
		if str(_loop_kind[key]) != "fire":
			continue
		var phase := float(_loop_phase.get(key, 0.0)) + delta * fire_flicker_speed
		_loop_phase[key] = phase
		var flicker := 1.0 + fire_flicker_amount * (sin(phase) * 0.6 + sin(phase * 2.7 + 1.3) * 0.4)
		var nodes: Array = _loops.get(key, [])
		for node: GPUParticles3D in nodes:
			node.scale = Vector3.ONE * flicker
		var light: Variant = _loop_lights.get(key)
		if light is OmniLight3D:
			(light as OmniLight3D).light_energy = fire_light_energy * flicker \
				* (1.0 - fire_light_flicker * randf())


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


## World position of a cell's floor (where the placement decal lies).
func _cell_floor(cell: Vector2i) -> Vector3:
	if kitchen == null:
		return Vector3(float(cell.x), hover_glow_height, float(cell.y))
	return kitchen.cell_to_world(cell) + Vector3(0.0, hover_glow_height, 0.0)


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
