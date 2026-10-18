class_name Roamers
extends Node3D
## Ambient horror: the customers outside the building.
##
## Placeholder guests — the same radioactive-green toilet as [Customer], built
## here as their own lightweight nodes — walk slowly along the *outside* of the
## walls, stop at windows, lean at the glass and growl. The threat is felt long
## before a day is actually lost.
##
## Purely presentation (invariant 11): nothing here reads or writes the
## simulation, no cells are reserved and no ticks are counted. The roamers are
## driven entirely by real time ([method _process]); the only link to the sim is
## listening for the day phase starting and for the mob breaking in, and the
## seeded RNG that makes the same day look the same every run.
##
## A crowd is *scattered*, never latticed: every roamer spawns on a seeded random
## spot of its face's stretch of perimeter (banded, with a real gap from its
## neighbours), walks at its own speed, bobs out of phase, keeps its own peek
## timing and claims a window before leaning at it — so eight of them read as a
## horde, not as a parade. All of it is a pure function of the seed.
##
## Wiring falls back to a tree search, so instancing [code]scenes/roamers.tscn[/code]
## anywhere under the world is enough. With [member auto_follow_day] on, the
## roamers appear when [DayController] enters the DAY phase (count from
## [member roamers_by_day]) and vanish the moment [member Service.mob_active]
## goes true — the real customers take over from there.
##
## Manual control:
## [codeblock]
## roamers.start_day(day.day)   # spawn that day's roamers, returns how many
## roamers.stop()               # despawn every roamer
## roamers.peek_now()           # tool/test hook: make them lean in right away
## [/codeblock]

const TOILET_SCENE := "res://assets/kenney_furniture-kit/Models/GLTF format/toilet.glb"

@export_group("Wiring")
## Optional explicit wiring; empty or stale paths fall back to a tree search.
@export var service_path: NodePath
@export var kitchen_path: NodePath
@export var day_path: NodePath
@export var audio_path: NodePath

@export_group("Schedule")
## How many roamers a day brings: index = day - 1, the last entry repeats for
## every later day (day 1 → 0, day 2 → 2, day 3 → 4, day 4 → 6, day 5+ → 8).
@export var roamers_by_day: Array[int] = [0, 2, 4, 6, 8]
## Seed base of the per-day RNG (day d uses seed_base + d * day_seed_stride).
@export var seed_base := 20261018
## Seed stride between days; also spaces out the per-roamer RNG streams.
@export var day_seed_stride := 7919
## Spawn on the DAY phase and clear on BUILD / SUMMARY (off = call
## [method start_day] yourself).
@export var auto_follow_day := true
## Clear the roamers the moment the mob breaks in ([signal Service.mob_started]).
@export var clear_on_mob := true

@export_group("Roamer look")
## Radioactive green, exactly like [Customer]'s placeholder tint.
@export var tint_color := Color(0.35, 1.0, 0.25)
## Scale of the toilet mesh (matches [member Service.customer_scale]).
@export var mesh_scale := 2.0
## Emission energy of the green glow while walking.
@export var glow_energy := 0.45
## Emission energy while leaning at a window (the stare brightens).
@export var peek_glow_energy := 1.15

@export_group("Perimeter")
## How far outside the wall line the roamers walk, in metres.
@export var patrol_offset := 1.45
## How close to the glass a peeking roamer leans, in metres from the wall line.
@export var peek_offset := 0.62
## How far a lone window's patrol line runs past it on each side, in metres.
@export var lone_patrol_reach := 1.6
## How far a spawn may sit past the outermost window of its face, in metres:
## the stretch a face's roamers share, so a crowd has room to spread.
@export var spawn_reach := 1.6
## Least distance between two roamers of one face at spawn, in metres (a spawn
## that lands closer is nudged along the wall until it fits).
@export var spawn_gap := 0.9
## How far a spawn may wander off the patrol line (towards or away from the
## glass), in metres: a group reads as a crowd, not as a lattice.
@export var spawn_drift := 0.3
## How far a roamer's peek may wander along the glass, in metres (two roamers
## sharing a window stand a lane apart, so a crowd never piles onto one spot).
@export var peek_drift := 0.32
## Walking speed in metres per second (a slow, deliberate shamble).
@export var walk_speed := 0.8
## Spread of the per-roamer speed multiplier: 0.15 = up to 15 % either way, so a
## group never marches in step.
@export_range(0.0, 0.5, 0.01) var speed_variation := 0.15
## Exponential smoothing rate of the turn toward the walk direction.
@export var turn_speed := 8.0
## How fast the body leans in and out at the glass.
@export var lean_speed := 6.0

@export_group("Hop")
## Vertical lift of the chunky hop while walking, in metres.
@export var hop_height := 0.16
## Hop rate, in radians per second.
@export var hop_rate := 9.0
## Spread of the per-roamer hop rate multiplier (same idea as
## [member speed_variation]): no two roamers bob in step.
@export_range(0.0, 0.5, 0.01) var hop_variation := 0.15
## Extra lift while leaning at a window, in metres.
@export var peek_lift := 0.05
## How far the body tips toward the glass while peeking, in degrees.
@export var peek_lean_degrees := 20.0

@export_group("Peeking")
## Seconds a roamer leans at the glass before walking on.
@export var peek_seconds := 2.6
## Chance a roamer stops at the next window it reaches (0 = never).
@export_range(0.0, 1.0, 0.05) var peek_chance := 0.55
## Shortest gap between two peeks of the same roamer, in seconds.
@export var peek_min_gap := 7.0
## Longest gap between two peeks of the same roamer, in seconds.
@export var peek_max_gap := 18.0

@export_group("Growl")
## Volume of a growl in dB (before the audio bank's master volume).
@export var growl_volume_db := -4.0
## Lowest pitch of a growl: well under 1.0 turns the creaks into wrong, low sounds.
@export var growl_pitch_min := 0.45
## Highest pitch of a growl.
@export var growl_pitch_max := 0.72
## Shortest gap between the two growls of one peek, in seconds.
@export var growl_gap_min := 0.7
## Longest gap between the two growls of one peek, in seconds.
@export var growl_gap_max := 1.6

@export_group("Light pulse")
## Flicker the sun for a beat when a roamer leans in (the lights notice).
@export var light_pulse_enabled := true
## How dark the flicker goes, as a fraction of the sun's resting energy.
@export_range(0.0, 1.0, 0.05) var light_pulse_depth := 0.55
## Seconds one flicker lasts.
@export var light_pulse_seconds := 0.55
## Minimum seconds between two flickers (a crowd must not strobe the lights).
@export var light_pulse_min_gap := 4.0

## The live roamers (tests and tools read this).
var roamers: Array[Roamer] = []
## The wall faces derived from the layout (tests read this).
var faces: Array[Dictionary] = []
## Day number of the last [method start_day] (0 = never started).
var last_day := 0

var service: Service
var kitchen: Kitchen
var day: DayController
var audio: AudioBank

var _faces_dirty := true
var _last_count := 0
var _last_seed := 0
var _sun: DirectionalLight3D
var _sun_base_energy := 0.0
var _sun_tween: Tween
var _last_pulse_msec := -1000000


func _ready() -> void:
	service = _resolve(service_path, "Service") as Service
	kitchen = _resolve(kitchen_path, "Kitchen") as Kitchen
	day = _resolve(day_path, "DayController") as DayController
	audio = _resolve(audio_path, "AudioBank") as AudioBank
	if audio == null:
		audio = _find_audio()
	if kitchen != null:
		kitchen.layout_rebuilt.connect(_on_layout_changed)
	if service != null and clear_on_mob:
		service.mob_started.connect(_on_mob_started)
	if day != null and auto_follow_day:
		day.phase_changed.connect(_on_phase_changed)
		if day.phase == DayController.Phase.DAY:
			start_day(day.day)


func _process(_delta: float) -> void:
	# Belt and braces: if the mob broke in while nobody told us (no wiring),
	# the roamers leave anyway.
	if clear_on_mob and not roamers.is_empty() and service != null and service.mob_active:
		stop()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Spawns the day's roamers around the building: the count comes from
## [member roamers_by_day] and the layout decides which windows they haunt.
## Returns how many roamers are out (0 when the day brings none, or when the
## kitchen has no window facing outside).
func start_day(day_number: int) -> int:
	last_day = day_number
	return start_count(roamers_for_day(day_number), seed_base + day_number * day_seed_stride)


## Spawns exactly [param count] roamers ([param seed_value] 0 = the last day's
## seed). Returns how many are out; the same count and seed always put them in
## the same places. Each roamer lands on a seeded random spot of its face's
## stretch of perimeter — banded, so a crowd spreads out instead of stacking on
## one lattice point — and keeps a real gap from its neighbours.
func start_count(count: int, seed_value := 0) -> int:
	stop()
	if count <= 0:
		return 0
	var seed := seed_value if seed_value != 0 else seed_base + last_day * day_seed_stride
	if _faces_dirty:
		_rebuild_perimeter()
		_faces_dirty = false
	if faces.is_empty():
		return 0
	_last_count = count
	_last_seed = seed
	var face_count := faces.size()
	# How many roamers each face carries, and the along-the-wall offsets already
	# taken on it (so two roamers can never share a spot).
	var per_face: Array[int] = []
	var taken: Array = []
	for f in face_count:
		per_face.append(0)
		var fresh: Array = []
		taken.append(fresh)
	for i in count:
		per_face[i % face_count] += 1
	var placed: Array[int] = []
	for f in face_count:
		placed.append(0)
	for i in count:
		var face_index := i % face_count
		var face: Dictionary = faces[face_index]
		var rng := RandomNumberGenerator.new()
		rng.seed = seed + i * 104729
		var slot := placed[face_index]
		var offset_list: Array = taken[face_index]
		var spawn := _spawn_point(face, slot, per_face[face_index], rng, offset_list)
		placed[face_index] = slot + 1
		var roamer := Roamer.new()
		roamer.name = "Roamer%d" % i
		roamer.top_level = true   # world space, wherever this node sits
		add_child(roamer)
		roamer.setup(self, rng, face, face_index, spawn)
		roamers.append(roamer)
	print("[roamers] %d roamer(s) on %d wall face(s) (day %d)" % [
		roamers.size(), faces.size(), last_day])
	return roamers.size()


## Despawns every roamer (the mob took over, or the day ended).
func stop() -> void:
	for roamer in roamers:
		roamer.queue_free()
	roamers.clear()
	_peek_holders.clear()
	_restore_light()


## Tool / test hook: make every roamer head for its window and lean in now.
func peek_now() -> void:
	for roamer in roamers:
		roamer.peek_now()


func is_active() -> bool:
	return not roamers.is_empty()


func active_count() -> int:
	return roamers.size()


## The day's roamer count: [member roamers_by_day] indexed by day - 1, clamped
## to the last entry (day 4 and later all bring the last number).
func roamers_for_day(day_number: int) -> int:
	if roamers_by_day.is_empty():
		return 0
	var index := clampi(day_number - 1, 0, roamers_by_day.size() - 1)
	return maxi(roamers_by_day[index], 0)


## A short flicker of the sun: the lights notice a roamer leaning in. Throttled,
## and always restored to the energy the sun had before the first flicker.
func pulse_light() -> void:
	if not light_pulse_enabled:
		return
	if _sun == null:
		_sun = _find_sun()
	if _sun == null:
		return
	var now := Time.get_ticks_msec()
	if now - _last_pulse_msec < int(light_pulse_min_gap * 1000.0):
		return
	_last_pulse_msec = now
	if _sun_base_energy <= 0.0:
		_sun_base_energy = _sun.light_energy
	if _sun_tween != null and _sun_tween.is_valid():
		_sun_tween.kill()
	_sun.light_energy = _sun_base_energy
	var dark := _sun_base_energy * (1.0 - light_pulse_depth)
	var step := light_pulse_seconds / 4.0
	_sun_tween = create_tween()
	_sun_tween.tween_property(_sun, "light_energy", dark, step * 0.4)
	_sun_tween.tween_property(_sun, "light_energy", _sun_base_energy, step * 0.6)
	_sun_tween.tween_property(_sun, "light_energy", dark * 0.9, step * 0.5)
	_sun_tween.tween_property(_sun, "light_energy", _sun_base_energy, step * 1.5)


## Plays one growl through the audio bank (safe when there is none).
func play_growl(file: String, position: Vector3, pitch: float, volume_db: float) -> void:
	if audio == null:
		return
	audio.play(AudioBank.RPG + file, position, pitch, volume_db)


# ---------------------------------------------------------------------------
# The perimeter: which windows face outside, and where to walk past them
# ---------------------------------------------------------------------------

## Builds one entry per outside wall face from the windows in the layout:
## patrol points along the wall and peek points at the glass. Faces with no
## window, and windows the mob already smashed, are ignored.
func _rebuild_perimeter() -> void:
	faces.clear()
	if kitchen == null or kitchen.data == null:
		return
	var groups := {}   # Vector2i outward normal -> Array of {along: float, wall: Vector3}
	for key: Vector3i in kitchen.data.walls:
		if int(kitchen.data.walls[key]) != KitchenLayout.Wall.WINDOW:
			continue
		if kitchen.is_broken(key):
			continue
		var cells := KitchenLayout.edge_cells(key)
		var inside := cells[0]
		var outside := cells[1]
		if not kitchen.has_floor(inside):
			var swap := inside
			inside = outside
			outside = swap
		if kitchen.has_floor(outside):
			continue   # both sides are floor: an interior window, nothing to haunt
		var normal := Vector2i(outside.x - inside.x, outside.y - inside.y)
		if not groups.has(normal):
			var fresh: Array = []
			groups[normal] = fresh
		var wall := Vector3(float(key.x) + 0.5, 0.0, float(key.y)) if key.z == KitchenLayout.DIR_X \
			else Vector3(float(key.x), 0.0, float(key.y) + 0.5)
		(groups[normal] as Array).append({
			"along": float(key.y) if key.z == KitchenLayout.DIR_X else float(key.x),
			"wall": wall,
		})
	var keys: Array[Vector2i] = []
	for normal: Vector2i in groups:
		keys.append(normal)
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y)
	for normal in keys:
		var entries: Array = groups[normal]
		entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a["along"]) < float(b["along"]))
		var normal3 := Vector3(float(normal.x), 0.0, float(normal.y))
		var along3 := Vector3(-normal3.z, 0.0, normal3.x)
		var patrol: Array[Vector3] = []
		var peeks: Array[Vector3] = []
		for entry: Dictionary in entries:
			var wall: Vector3 = entry["wall"]
			patrol.append(wall + normal3 * patrol_offset)
			peeks.append(wall + normal3 * peek_offset)
		if patrol.size() == 1:
			# One lone window: give the walker somewhere to walk to.
			patrol.insert(0, patrol[0] - along3 * lone_patrol_reach)
			patrol.append(patrol[1] + along3 * lone_patrol_reach)
		faces.append({
			"normal": normal3,
			"along": along3,
			"patrol": patrol,
			"peeks": peeks,
			"facing": atan2(-normal3.x, -normal3.z),
		})


## A seeded random spot along [param face]'s stretch of perimeter for roamer
## [param slot] of [param total] sharing that face. The stretch runs
## [member spawn_reach] metres past the outermost window at either end; each
## roamer owns a band of it (so a group spreads out) and [param taken] — the
## along-the-wall offsets already used on this face — keeps a real gap between
## neighbours. The lateral drift is the only thing that leaves the patrol line.
func _spawn_point(face: Dictionary, slot: int, total: int, rng: RandomNumberGenerator,
		taken: Array) -> Vector3:
	var patrol: Array[Vector3] = face["patrol"]
	if patrol.is_empty():
		return Vector3.ZERO
	var normal: Vector3 = face["normal"]
	# The stretch runs from the first to the last patrol point, which is not
	# always the face's `along` axis (the entries are sorted by the raw layout
	# coordinate, and a face's normal can point either way), so derive the
	# direction from the points themselves.
	var span_vec := patrol[patrol.size() - 1] - patrol[0]
	var span := span_vec.length() + spawn_reach * 2.0
	var dir := span_vec.normalized() if span_vec.length_squared() > 0.0001 \
		else (face["along"] as Vector3)
	var start := patrol[0] - dir * spawn_reach
	var band := span / float(maxi(total, 1))
	var offset := (float(slot) + rng.randf_range(0.12, 0.88)) * band
	var gap := maxf(spawn_gap, 0.01)
	var tries := 0
	while _too_close(offset, taken, gap) and tries < 12:
		offset = fposmod(offset + gap, maxf(span, gap))
		tries += 1
	taken.append(offset)
	return start + dir * offset + normal * rng.randf_range(-spawn_drift, spawn_drift)


func _too_close(offset: float, taken: Array, gap: float) -> bool:
	for other: float in taken:
		if absf(offset - other) < gap:
			return true
	return false


# ---------------------------------------------------------------------------
# Peek claims: which window each roamer leans at
# ---------------------------------------------------------------------------
# Roamers ask before they start a peek, so a group spreads over the face's
# windows instead of piling onto the nearest one. Claims are per face and per
# peek point, held until the roamer walks off (or is despawned).

var _peek_holders: Dictionary = {}   # face index -> { peek index -> Roamer }


## The peek point of [param face_index] roamer [param roamer] should lean at: the
## nearest one nobody else holds, else the nearest of all (it still peeks). The
## returned dictionary carries `index` and a `lane` — how many roamers already
## stand at that window, which the caller turns into a sideways offset so two
## sharing one window never stand inside each other.
func claim_peek(face_index: int, roamer: Roamer, from: Vector3) -> Dictionary:
	if face_index < 0 or face_index >= faces.size():
		return {"index": -1, "lane": 0}
	var peeks: Array[Vector3] = faces[face_index]["peeks"]
	if peeks.is_empty():
		return {"index": -1, "lane": 0}
	var held := _holders(face_index)
	var best := -1
	var best_dist := 1.0e30
	var fallback := -1
	var fallback_dist := 1.0e30
	for i in peeks.size():
		var dist := from.distance_squared_to(peeks[i])
		if dist < fallback_dist:
			fallback_dist = dist
			fallback = i
		if held.has(i) and held[i] != roamer:
			continue
		if dist < best_dist:
			best_dist = dist
			best = i
	if best < 0:
		best = fallback
	var lane := 0
	for key in held.keys():
		if int(key) == best and held[key] != roamer:
			lane += 1
	held[best] = roamer
	return {"index": best, "lane": lane}


## Lets go of the window [param roamer] was leaning at (safe to call twice).
func release_peek(face_index: int, roamer: Roamer) -> void:
	if face_index < 0 or face_index >= faces.size():
		return
	var held := _holders(face_index)
	for key in held.keys():
		if held[key] == roamer:
			held.erase(key)


func _holders(face_index: int) -> Dictionary:
	if not _peek_holders.has(face_index):
		var fresh := {}
		_peek_holders[face_index] = fresh
	return _peek_holders[face_index]


# ---------------------------------------------------------------------------
# Wiring helpers
# ---------------------------------------------------------------------------

func _on_phase_changed(phase: int) -> void:
	if phase == DayController.Phase.DAY:
		start_day(day.day if day != null else last_day + 1)
	else:
		stop()


func _on_mob_started(_edges: Array) -> void:
	stop()


func _on_layout_changed() -> void:
	_faces_dirty = true
	if roamers.is_empty():
		return
	# The map changed under them (build phase edit): re-derive the perimeter and
	# put the same roamers back on it, deterministic as ever.
	var count := _last_count
	var seed := _last_seed
	stop()
	start_count(count, seed)


func _resolve(path: NodePath, hint: String) -> Node:
	if not path.is_empty():
		var direct := get_node_or_null(path)
		if direct != null:
			return direct
	for candidate in ["../" + hint, "../../" + hint, "../../../" + hint]:
		var node := get_node_or_null(candidate)
		if node != null:
			return node
	var root := _scene_root()
	if root != null:
		return root.find_child(hint, true, false)
	return null


func _find_audio() -> AudioBank:
	var root := _scene_root()
	if root == null:
		return null
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is AudioBank:
			return node as AudioBank
		for child in node.get_children():
			stack.append(child)
	return null


func _find_sun() -> DirectionalLight3D:
	var root := _scene_root()
	if root == null:
		return null
	var named := root.find_child("Sun", true, false) as DirectionalLight3D
	if named != null:
		return named
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is DirectionalLight3D:
			return node as DirectionalLight3D
		for child in node.get_children():
			stack.append(child)
	return null


func _scene_root() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.current_scene if tree.current_scene != null else tree.root


func _restore_light() -> void:
	if _sun_tween != null and _sun_tween.is_valid():
		_sun_tween.kill()
	if _sun != null and _sun_base_energy > 0.0:
		_sun.light_energy = _sun_base_energy


# ---------------------------------------------------------------------------
# One walker
# ---------------------------------------------------------------------------

## A single customer outside the wall: it walks its face of the building in real
## time, stops at a window now and then, leans at the glass and growls. It never
## touches the simulation.
class Roamer extends Node3D:
	enum Mode { PATROL, TO_PEEK, PEEK, BACK }

	## Pitch-shifted into growls: the creaks of the building, and cloth (breath).
	const GROWLS: Array[String] = ["creak1.ogg", "creak2.ogg", "creak3.ogg", "cloth4.ogg"]

	var host: Roamers
	var rng := RandomNumberGenerator.new()
	var mode := Mode.PATROL
	var wall_facing := 0.0
	var face_index := -1
	var patrol: Array[Vector3] = []
	var peeks: Array[Vector3] = []
	var along_dir := Vector3.RIGHT
	var patrol_index := 0
	var patrol_dir := 1
	var peek_index := 0
	var peek_claim := -1
	## How many customers already stood at that window when this one claimed it
	## (0 = first): a sideways lane, so a shared window still reads as a crowd.
	var peek_lane := 0
	## Per-roamer multipliers: no two of a group walk or hop at the same rate.
	var speed_scale := 1.0
	var hop_scale := 1.0

	var _visual_from := Vector3.ZERO
	var _visual_to := Vector3.ZERO
	var _move_elapsed := 0.0
	var _move_duration := 0.0
	var _hop := 0.0
	var _facing := 0.0
	var _lean := 0.0
	var _peek_left := 0.0
	var _peek_cooldown := 0.0
	var _growls_left := 0
	var _growl_left := 0.0
	var _glow := 0.0
	var _mesh_height := 0.0
	var _body: Node3D
	var _materials: Array[StandardMaterial3D] = []


	func setup(p_host: Roamers, p_rng: RandomNumberGenerator, face: Dictionary,
			index: int, spawn: Vector3) -> void:
		host = p_host
		rng = p_rng
		face_index = index
		wall_facing = face["facing"]
		patrol = face["patrol"]
		peeks = face["peeks"]
		along_dir = face["along"]
		position = spawn
		_visual_from = spawn
		_visual_to = spawn
		_facing = wall_facing + PI
		rotation.y = _facing
		# A little either way on the walk and the bob, and a random point in the
		# hop cycle: a group never lines up or marches in step.
		speed_scale = 1.0 + rng.randf_range(-host.speed_variation, host.speed_variation)
		hop_scale = 1.0 + rng.randf_range(-host.hop_variation, host.hop_variation)
		_hop = rng.randf() * TAU
		_build_body()
		_peek_cooldown = rng.randf_range(host.peek_min_gap * 0.2, host.peek_max_gap)
		if patrol.size() > 1:
			# Walk off towards the nearest patrol point, either way along the
			# wall: two roamers dropped side by side still part company.
			patrol_index = _nearest_patrol()
			patrol_dir = 1 if rng.randf() < 0.5 else -1
			if patrol_index <= 0:
				patrol_dir = 1
			elif patrol_index >= patrol.size() - 1:
				patrol_dir = -1
			_walk_to(patrol[patrol_index])


	## Test / tool hook: head for the nearest free window and lean in right away.
	func peek_now() -> void:
		_peek_cooldown = 0.0
		_start_peek()


	func is_peeking() -> bool:
		return mode == Mode.PEEK


	# --- presentation ------------------------------------------------------

	func _process(delta: float) -> void:
		if host == null:
			return
		if _move_duration > 0.0:
			_move_elapsed = minf(_move_elapsed + delta, _move_duration)
			var t := _move_elapsed / _move_duration
			position = _visual_from.lerp(_visual_to, smoothstep(0.0, 1.0, t))
			_hop += delta * host.hop_rate * hop_scale
			if _move_elapsed >= _move_duration:
				_move_duration = 0.0
				position = _visual_to
				_arrive()
		match mode:
			Mode.PEEK:
				_peek_left -= delta
				if _growls_left > 0:
					_growl_left -= delta
					if _growl_left <= 0.0:
						_growl()
				if _peek_left <= 0.0:
					_end_peek()
			Mode.PATROL, Mode.BACK:
				_peek_cooldown = maxf(_peek_cooldown - delta, 0.0)
			_:
				pass
		rotation.y = lerp_angle(rotation.y, _facing, 1.0 - exp(-host.turn_speed * delta))
		var lift := 0.0
		if _move_duration > 0.0:
			lift = absf(sin(_hop)) * host.hop_height
		elif mode == Mode.PEEK:
			lift = host.peek_lift * (0.5 + 0.5 * sin(_hop * 0.9))
		_body.position.y = lift
		_body.rotation.x = lerp(_body.rotation.x, _lean, 1.0 - exp(-host.lean_speed * delta))
		var target_glow := host.peek_glow_energy if mode == Mode.PEEK else host.glow_energy
		_glow = lerp(_glow, target_glow, 1.0 - exp(-4.0 * delta))
		var pulse := _glow + sin(_hop * 0.8) * 0.08
		for mat in _materials:
			mat.emission_energy_multiplier = pulse


	## Radioactive glow: the placeholder art is the toilet mesh in a loud green
	## (same recipe as [method Customer._glow]).
	func _build_body() -> void:
		_body = Node3D.new()
		add_child(_body)
		var scene := load(Roamers.TOILET_SCENE) as PackedScene
		if scene == null:
			return
		var model := scene.instantiate() as Node3D
		model.scale = Vector3.ONE * host.mesh_scale
		_body.add_child(model)
		var aabb := MeshBounds.combined_aabb(model)
		if aabb.size != Vector3.ZERO:
			var center := aabb.get_center()
			model.position -= Vector3(center.x, aabb.position.y, center.z)
			_mesh_height = aabb.size.y
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
							mat.albedo_color = (src as BaseMaterial3D).albedo_color * host.tint_color
						else:
							mat.albedo_color = host.tint_color
						mat.emission_enabled = true
						mat.emission = host.tint_color
						mat.emission_energy_multiplier = host.glow_energy
						mi.set_surface_override_material(i, mat)
						_materials.append(mat)
						_glow = host.glow_energy
			for child in node.get_children():
				stack.append(child)


	# --- walking -----------------------------------------------------------

	func _walk_to(target: Vector3) -> void:
		_visual_from = position
		_visual_to = target
		_move_elapsed = 0.0
		_move_duration = maxf(position.distance_to(target)
			/ maxf(host.walk_speed * speed_scale, 0.01), 0.05)
		var dir := _visual_to - _visual_from
		if dir.length_squared() > 0.0001:
			_facing = atan2(dir.x, dir.z)


	func _walk_to_patrol() -> void:
		if not patrol.is_empty():
			_walk_to(patrol[clampi(patrol_index, 0, patrol.size() - 1)])


	## Index of the patrol point closest to where this roamer stands.
	func _nearest_patrol() -> int:
		var best := 0
		var best_dist := 1.0e30
		for i in patrol.size():
			var dist := position.distance_squared_to(patrol[i])
			if dist < best_dist:
				best_dist = dist
				best = i
		return best


	func _arrive() -> void:
		match mode:
			Mode.TO_PEEK:
				mode = Mode.PEEK
				_peek_left = host.peek_seconds * rng.randf_range(0.7, 1.3)
				_facing = wall_facing
				_lean = deg_to_rad(host.peek_lean_degrees)
				_growls_left = 2
				_growl_left = 0.0
				_growl()
				host.pulse_light()
			Mode.BACK:
				mode = Mode.PATROL
				_peek_cooldown = rng.randf_range(host.peek_min_gap, host.peek_max_gap)
				_advance_patrol()
				_walk_to_patrol()
			Mode.PATROL:
				if _peek_cooldown <= 0.0 and rng.randf() < host.peek_chance:
					_start_peek()
				else:
					_advance_patrol()
					_walk_to_patrol()
			_:
				pass


	func _advance_patrol() -> void:
		if patrol.size() <= 1:
			return
		patrol_index += patrol_dir
		if patrol_index >= patrol.size():
			patrol_index = patrol.size() - 2
			patrol_dir = -1
		elif patrol_index < 0:
			patrol_index = 1
			patrol_dir = 1


	# --- peeking -----------------------------------------------------------

	func _start_peek() -> void:
		if peeks.is_empty():
			_advance_patrol()
			_walk_to_patrol()
			return
		_release_peek()
		var claim := host.claim_peek(face_index, self, position)
		peek_index = int(claim["index"])
		if peek_index < 0:
			_advance_patrol()
			_walk_to_patrol()
			return
		peek_claim = peek_index
		peek_lane = int(claim["lane"])
		mode = Mode.TO_PEEK
		_lean = 0.0
		_walk_to(peeks[peek_index] + _peek_offset())


	func _end_peek() -> void:
		_lean = 0.0
		_release_peek()
		mode = Mode.BACK
		_walk_to_patrol()


	## A little along the glass, one lane per roamer already at that window: two
	## customers sharing one window still stand apart instead of inside each other.
	func _peek_offset() -> Vector3:
		if host == null or host.peek_drift <= 0.0 or peek_lane <= 0:
			return Vector3.ZERO
		var step := ceilf(float(peek_lane) / 2.0)
		var side := 1.0 if (peek_lane % 2) == 1 else -1.0
		return along_dir * host.peek_drift * step * side


	func _release_peek() -> void:
		if peek_claim >= 0 and host != null:
			host.release_peek(face_index, self)
		peek_claim = -1


	func _exit_tree() -> void:
		_release_peek()


	func _growl() -> void:
		_growls_left -= 1
		_growl_left = rng.randf_range(host.growl_gap_min, host.growl_gap_max)
		var file: String = GROWLS[rng.randi_range(0, GROWLS.size() - 1)]
		host.play_growl(file, global_position + Vector3.UP * (_mesh_height * 0.6),
			rng.randf_range(host.growl_pitch_min, host.growl_pitch_max), host.growl_volume_db)
