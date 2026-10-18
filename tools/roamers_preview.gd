extends Node
## Roamers preview + verification tool. Instances the real demo kitchen in a
## SubViewport, adds [code]scenes/roamers.tscn[/code] the way main.tscn will,
## starts a day and proves the ambient horror is on screen: green customers
## outside the wall, leaning at a window, gone the moment the mob breaks in.
##
##   roamers_A_patrol.png   roamers walking the outside of the wall (wide)
##   roamers_B_peek.png     one leaning at the glass (close)
##   roamers_C_gone.png     after stop(): the frame is clean again
##
## Run with:
##   DISPLAY=:1 godot --path . res://tools/roamers_preview.tscn
## Exits with code 1 when a check fails.

const OUT_DIR := "/tmp/opencode"
const VIEW := Vector2i(1280, 720)
## The camera pitch is 50°, so a 2.4 m wall hides about 2 m of ground behind it:
## look from the north-west (+ a yaw of 225°) to see the north and west walls.
const CAMERA_YAW := 225.0
const WIDE_DISTANCE := 15.0
const CLOSE_DISTANCE := 8.5

var _sub: SubViewport
var _scene: Node
var _world: SubViewport
var _kitchen: Kitchen
var _service: Service
var _day: DayController
var _rig: CameraRig
var _cam: Camera3D
var _roamers: Roamers
var _sun: DirectionalLight3D
var _sun_resting := 0.0
var _failures := 0


func _ready() -> void:
	_sub = SubViewport.new()
	_sub.size = VIEW
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sub)
	_scene = load("res://scenes/main.tscn").instantiate()
	var pinned := _scene.find_child("Kitchen", true, false) as Kitchen
	if pinned != null:
		pinned.layout_file = "res://resources/layouts/demo_kitchen.txt"
	_sub.add_child(_scene)
	await get_tree().process_frame
	_world = _scene.find_child("World", true, false) as SubViewport
	_kitchen = _scene.find_child("Kitchen", true, false) as Kitchen
	_service = _scene.find_child("Service", true, false) as Service
	_day = _scene.find_child("DayController", true, false) as DayController
	_rig = _scene.find_child("CameraRig", true, false) as CameraRig
	_sun = _scene.find_child("Sun", true, false) as DirectionalLight3D
	if _world == null or _kitchen == null or _service == null or _rig == null or _day == null:
		print("[preview] FAIL - the demo scene did not load (world=%s kitchen=%s service=%s rig=%s day=%s)"
			% [_world, _kitchen, _service, _rig, _day])
		get_tree().quit(1)
		return
	_cam = _rig.get_node_or_null("Camera3D") as Camera3D
	_disable_placer()
	# The roamers are presentation only: freeze the simulation so nothing else
	# moves in the frame while the walkers do their slow walk.
	_service.sim_speed = 0.0
	if _sun != null:
		_sun_resting = _sun.light_energy

	# The game's own wiring: main.tscn's World/Roamers is already there, wired by
	# path. Use it — the intro's reveal horde goes to that very node, so a second
	# instance would put the crowd somewhere else entirely.
	_roamers = _scene.find_child("Roamers", true, false) as Roamers
	if _roamers == null:
		_roamers = load("res://scenes/roamers.tscn").instantiate() as Roamers
		_roamers.name = "Roamers"
		_world.add_child(_roamers)
	await _settle(3)

	_check_wiring()
	_check_schedule()
	await _check_auto_follow()
	await _check_perimeter()
	await _check_spawn_scatter()
	await _check_determinism()
	await _check_walk_and_peek()
	await _check_clear_and_mob()
	await _check_start_map()
	await _check_intro()

	print("[preview] %s (%d failures)" % ["FAIL" if _failures > 0 else "ok", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

func _check_wiring() -> void:
	_expect(_roamers.service == _service, "wiring: the service is found")
	_expect(_roamers.kitchen == _kitchen, "wiring: the kitchen is found")
	_expect(_roamers.day == _day, "wiring: the day controller is found")
	_expect(_roamers.audio != null, "wiring: the audio bank is found (Fx/AudioBank)")
	_expect(_roamers.active_count() == 0, "wiring: nothing spawns in the build phase")


func _check_schedule() -> void:
	_expect(_roamers.roamers_for_day(1) == 0, "schedule: day 1 brings nobody")
	_expect(_roamers.roamers_for_day(2) == 2, "schedule: day 2 brings 2")
	_expect(_roamers.roamers_for_day(3) == 4, "schedule: day 3 brings 4")
	_expect(_roamers.roamers_for_day(4) == 6, "schedule: day 4 brings 6")
	_expect(_roamers.roamers_for_day(5) == 8, "schedule: day 5 brings 8")
	_expect(_roamers.roamers_for_day(9) == 8, "schedule: later days stay at 8 (clamped)")


## The day phase starts them on its own (no manual call), through the real
## [signal DayController.phase_changed] signal.
func _check_auto_follow() -> void:
	var saved := _roamers.roamers_by_day
	var counts: Array[int] = []
	counts.append(1)
	counts.append(2)
	_roamers.roamers_by_day = counts
	_day.start_day()
	await _settle(2)
	_expect(_roamers.active_count() == 1, "auto: the DAY phase spawned the day's roamer (got %d)"
		% _roamers.active_count())
	_roamers.stop()
	await _settle(2)
	_expect(_roamers.active_count() == 0, "auto: stop() clears them")
	_roamers.roamers_by_day = saved


func _check_perimeter() -> void:
	var spawned := _roamers.start_day(4)
	_expect(spawned == 6, "spawn: day 4 brings 6 roamers (got %d)" % spawned)
	_expect(_roamers.faces.size() >= 2, "perimeter: %d outside wall face(s) with windows"
		% _roamers.faces.size())
	# Every patrol point and every peek point must be outside the building.
	var total := 0
	var outside := 0
	for face: Dictionary in _roamers.faces:
		var patrol: Array[Vector3] = face["patrol"]
		var peeks: Array[Vector3] = face["peeks"]
		for p in patrol + peeks:
			total += 1
			if not _kitchen.has_floor(_kitchen.world_to_cell(p)):
				outside += 1
	_expect(outside == total, "perimeter: every patrol/peek point is outside the building (%d/%d)"
		% [outside, total])
	# Every peek point must sit at a real window of the layout.
	var windows: Array[Vector3] = []
	for key: Vector3i in _kitchen.data.walls:
		if int(_kitchen.data.walls[key]) != KitchenLayout.Wall.WINDOW:
			continue
		var centre := Vector3(float(key.x) + 0.5, 0.0, float(key.y)) if key.z == KitchenLayout.DIR_X \
			else Vector3(float(key.x), 0.0, float(key.y) + 0.5)
		windows.append(centre)
	var worst := 0.0
	for face: Dictionary in _roamers.faces:
		var peeks: Array[Vector3] = face["peeks"]
		for p in peeks:
			var best := 1.0e30
			for w in windows:
				best = minf(best, p.distance_to(w))
			worst = maxf(worst, best)
	_expect(worst < 0.75, "perimeter: every peek point is at a window (worst %.2f m, %d windows)"
		% [worst, windows.size()])
	# And every roamer stands on void, never inside.
	for roamer in _roamers.roamers:
		var cell := _kitchen.world_to_cell(roamer.global_position)
		_expect(not _kitchen.has_floor(cell), "spawn: %s is outside the building at cell %s"
			% [roamer.name, cell])
		if not _roamers.roamers.is_empty() and roamer == _roamers.roamers[0]:
			print("[preview] roamer mesh height %.2f m, peek line %.2f m, patrol line %.2f m"
				% [roamer._mesh_height, _roamers.peek_offset, _roamers.patrol_offset])
	for i in _roamers.faces.size():
		var face: Dictionary = _roamers.faces[i]
		var patrol: Array[Vector3] = face["patrol"]
		var peeks: Array[Vector3] = face["peeks"]
		print("[preview] face %d normal %s: %d window(s), patrol %s, peek %s"
			% [i, face["normal"], peeks.size(), patrol, peeks])


## "Seeded RNG so the same day looks the same": the spawn points of one day are
## identical on every call, and another seed moves the crowd. Read straight after
## the spawn (a settle would let them take a step and blur the comparison).
func _check_determinism() -> void:
	_roamers.start_count(6, 4242)
	var first: Array[Vector3] = []
	for roamer in _roamers.roamers:
		first.append(roamer.global_position)
	_roamers.start_count(6, 4242)
	var again: Array[Vector3] = []
	for roamer in _roamers.roamers:
		again.append(roamer.global_position)
	var same := first.size() == again.size() and first.size() == 6
	if same:
		for i in first.size():
			if first[i].distance_to(again[i]) > 0.001:
				same = false
	_expect(same, "determinism: the same count and seed put 6 roamers in the same places")
	# A different seed is a different crowd (the scatter is seeded, not fixed).
	_roamers.start_count(6, 777)
	var moved := 0
	for i in mini(first.size(), _roamers.roamers.size()):
		if first[i].distance_to(_roamers.roamers[i].global_position) > 0.05:
			moved += 1
	_expect(moved >= 3, "determinism: another seed puts the crowd somewhere else (%d of %d moved)"
		% [moved, first.size()])
	await _settle(2)


## The scatter itself: a crowd never lands on one lattice point, never shares a
## spot, and never all walks or bobs at the same rate.
func _check_spawn_scatter() -> void:
	var spawned := _roamers.start_count(8, 424242)
	_expect(spawned == 8, "scatter: start_count(8) puts 8 roamers out (got %d)" % spawned)
	var worst := 1.0e30
	var closest := ""
	for i in _roamers.roamers.size():
		for j in range(i + 1, _roamers.roamers.size()):
			var a := _roamers.roamers[i]
			var b := _roamers.roamers[j]
			var gap := a.global_position.distance_to(b.global_position)
			if gap < worst:
				worst = gap
				closest = "%s/%s" % [a.name, b.name]
	print("[preview] scatter: closest pair %s at %.3f m" % [closest, worst])
	_expect(worst > 0.5, "scatter: no two roamers spawn on the same spot (closest %.3f m)" % worst)
	# Not on the patrol lattice: most spawns sit off every patrol point.
	var off_lattice := 0
	var drift := 0.0
	for roamer in _roamers.roamers:
		var best := 1.0e30
		for point in roamer.patrol:
			best = minf(best, roamer.global_position.distance_to(point))
		drift = maxf(drift, best)
		if best > 0.1:
			off_lattice += 1
	print("[preview] scatter: %d of %d spawns sit off the patrol points (worst offset %.2f m)"
		% [off_lattice, _roamers.roamers.size(), drift])
	_expect(off_lattice >= 6, "scatter: the crowd is scattered, not latticed (%d of %d off-lattice)"
		% [off_lattice, _roamers.roamers.size()])
	# Every roamer keeps its own walk/bob rate and its own phase.
	var speeds: Array[float] = []
	var hops: Array[float] = []
	for roamer in _roamers.roamers:
		speeds.append(roamer.speed_scale)
		hops.append(roamer.hop_scale)
	var speed_spread: float = speeds.max() - speeds.min()
	var hop_spread: float = hops.max() - hops.min()
	print("[preview] scatter: speed %.3f..%.3f, hop rate x%.3f..%.3f"
		% [speeds.min(), speeds.max(), hops.min(), hops.max()])
	_expect(speed_spread > 0.05, "scatter: the roamers walk at different speeds (spread %.3f)" % speed_spread)
	_expect(hop_spread > 0.05, "scatter: the roamers bob out of step (spread %.3f)" % hop_spread)
	# And every spawn is outside the building (nothing lands in a room).
	for roamer in _roamers.roamers:
		var cell := _kitchen.world_to_cell(roamer.global_position)
		_expect(not _kitchen.has_floor(cell), "scatter: %s spawns outside the building at %s"
			% [roamer.name, cell])


func _check_walk_and_peek() -> void:
	_rig._yaw_deg = CAMERA_YAW
	await _rig.focus_world(Vector3.ZERO, 18.0, 0.05)
	await _settle(4)
	var facing := _camera_facing_faces()
	_expect(not facing.is_empty(), "camera: at least one wall with windows faces the camera")

	# --- wide shot: everyone on their patrol line --------------------------
	_roamers.start_day(4)
	var bounds := _kitchen.data.floor_bounds()
	var middle := _kitchen.cell_to_world(bounds.position + bounds.size / 2)
	await _rig.focus_world(middle, WIDE_DISTANCE, 0.05)
	await _settle(4)
	await _wait_seconds(1.2)          # let them get walking
	var wide: Image = await _shot("A_patrol")
	var visible := 0
	for roamer in _roamers.roamers:
		var screen := _cam.unproject_position(roamer.global_position + Vector3.UP * 0.6)
		if _greenest_around(wide, screen, 16) > 0.12:
			visible += 1
	_expect(visible >= 3, "render: %d of %d roamers show as green shapes outside the wall"
		% [visible, _roamers.roamers.size()])
	var green_wide := _green_pixels(wide)
	_expect(green_wide > 20, "render: the wide frame has green in it (%d samples)" % green_wide)

	# --- close shot: leaning at the glass ---------------------------------
	_roamers.peek_now()
	var peeking := await _wait_for_peek(3, 10.0)
	_expect(peeking > 0, "peek: %d roamer(s) reached the glass" % peeking)
	# Watch the sun while they lean in (the flicker is short).
	var dimmest := _sun_resting
	for i in 90:
		dimmest = minf(dimmest, _sun.light_energy)
		await get_tree().process_frame
	var close_face := _busiest_facing_face(facing)
	await _rig.focus_world(_face_centre(close_face), CLOSE_DISTANCE, 0.05)
	await _settle(4)
	_roamers.peek_now()
	await _wait_for_peek(1, 6.0)
	await _wait_seconds(0.5)          # let the stare brighten
	var close: Image = await _shot("B_peek")
	var leaning := 0
	for roamer in _roamers.roamers:
		if not roamer.is_peeking() or _nearest_face(roamer.global_position) != close_face:
			continue
		leaning += 1
		var screen := _cam.unproject_position(roamer.global_position + Vector3.UP * 0.6)
		_expect(_greenest_around(close, screen, 16) > 0.12,
			"render: the leaning roamer is green at the glass (%.0f, %.0f)" % [screen.x, screen.y])
		_expect(roamer._body.rotation.x > 0.12,
			"peek: the body leans toward the glass (%.2f rad)" % roamer._body.rotation.x)
		_expect(roamer._materials.size() > 0 and roamer._materials[0].emission_energy_multiplier > 0.95,
			"peek: the glow brightens while staring in (%.2f)"
				% roamer._materials[0].emission_energy_multiplier)
	_expect(leaning > 0, "render: at least one roamer is leaning in the close frame")
	_expect(dimmest < _sun_resting - 0.02,
		"lights: the sun flickered while they leaned in (%.3f -> %.3f)" % [_sun_resting, dimmest])
	_roamers.stop()
	await _settle(4)
	_expect(absf(_sun.light_energy - _sun_resting) < 0.02,
		"lights: the sun is back to its resting energy (%.3f)" % _sun.light_energy)
	var gone: Image = await _shot("C_gone")
	var green_gone := _green_pixels(gone)
	_expect(green_gone < green_wide / 2,
		"render: the roamers are gone from the frame (%d -> %d green samples)" % [green_wide, green_gone])


## The mob breaks in: the roamers must vanish for the real customers.
func _check_clear_and_mob() -> void:
	_roamers.start_day(4)
	await _settle(2)
	_expect(_roamers.active_count() == 6, "mob: the roamers are out again")
	_service.mob_started.emit([])
	await _settle(3)
	_expect(_roamers.active_count() == 0, "mob: they are gone the moment the mob breaks in")
	# And the belt-and-braces guard in _process (no signal): mob_active alone.
	_roamers.start_day(4)
	await _settle(2)
	_service.mob_active = true
	await _settle(3)
	_expect(_roamers.active_count() == 0, "mob: mob_active alone clears them too")
	_service.mob_active = false
	# The explicit entry point: a count and a seed, no day arithmetic.
	_expect(_roamers.start_count(2, 12345) == 2, "api: start_count(2) spawns 2")
	_expect(_roamers.start_count(0) == 0, "api: start_count(0) clears them")


# ---------------------------------------------------------------------------
# Scene helpers
# ---------------------------------------------------------------------------

## The same perimeter logic on the map the game actually boots: a bare Kitchen
## with the start layout and a second Roamers node wired straight to it.
func _check_start_map() -> void:
	var start_kitchen := Kitchen.new()
	start_kitchen.name = "StartKitchen"
	start_kitchen.layout_file = "res://resources/layouts/start_kitchen.txt"
	start_kitchen.build_walls = false
	_world.add_child(start_kitchen)
	await _settle(2)
	var extra := load("res://scenes/roamers.tscn").instantiate() as Roamers
	extra.name = "StartRoamers"
	extra.auto_follow_day = false
	extra.clear_on_mob = false
	extra.kitchen_path = start_kitchen.get_path()
	extra.service_path = NodePath("")   # no sim needed: presentation only
	extra.day_path = NodePath("")
	extra.audio_path = NodePath("")
	_world.add_child(extra)
	await _settle(2)
	var spawned := extra.start_day(4)
	_expect(spawned == 6, "start map: 6 roamers out (got %d)" % spawned)
	_expect(extra.faces.size() >= 2, "start map: %d outside wall face(s) with windows"
		% extra.faces.size())
	var total := 0
	var outside := 0
	for face: Dictionary in extra.faces:
		var patrol: Array[Vector3] = face["patrol"]
		var peeks: Array[Vector3] = face["peeks"]
		for p in patrol + peeks:
			total += 1
			if not start_kitchen.has_floor(start_kitchen.world_to_cell(p)):
				outside += 1
	_expect(outside == total, "start map: every patrol/peek point is outside (%d/%d)" % [outside, total])
	for roamer in extra.roamers:
		_expect(not start_kitchen.has_floor(start_kitchen.world_to_cell(roamer.global_position)),
			"start map: %s is outside the building at cell %s"
				% [roamer.name, start_kitchen.world_to_cell(roamer.global_position)])
	extra.stop()
	extra.queue_free()
	start_kitchen.queue_free()
	await _settle(2)


## The intro's two new beats, played for real through the game UI: the tight
## shrine framing for card 2 and the customers filling the windows for card 4.
## Also proves the guard (nothing spawns while the menu is up) and the fallback
## (a venue without a shrine skips the beat instead of aiming at nothing).
func _check_intro() -> void:
	var ui := _scene.get_node_or_null("UI")
	var intro := ui.intro as IntroSequence if ui != null else null
	if ui == null or intro == null:
		_expect(false, "intro: the UI carries the intro sequence")
		return
	# Nothing may spawn while the menu is up: the guard in _spawn_horde.
	intro._spawn_horde()
	await _settle(2)
	_expect(_roamers.active_count() == 0, "intro: no horde while the menu is up (%d out)"
		% _roamers.active_count())
	# The intro plays in the build phase, with the kitchen fullscreen and the
	# camera at its authored yaw (the day checks above left the game mid-day and
	# the camera turned to look at the north-west walls).
	_day.phase = DayController.Phase.BUILD
	_day.phase_changed.emit(_day.phase)
	_rig._yaw_deg = 0.0
	await _settle(2)
	# The venue the game really plays: the shrine lives in the start map.
	_kitchen.load_layout("res://resources/layouts/start_kitchen.txt")
	await _settle(2)
	ui.start_game(false)
	var shrine := _shrine_instance()
	if shrine == null:
		_expect(false, "intro: the start map places a corporate_shrine")
		return
	var shrine_pos := shrine.global_position

	# --- card 2: the tight shrine beat ------------------------------------
	var got_card2 := await _wait_for_card(intro, 1, 25.0)
	_expect(got_card2, "intro: card 2 (the apps went to war) comes up")
	_expect(str(intro.beat) == "card", "intro: card 2 is up (beat %s)" % str(intro.beat))
	_expect(intro.shrine_cell == shrine.anchor, "intro: the beat found the shrine at %s (got %s)"
		% [shrine.anchor, intro.shrine_cell])
	_expect(absf(_rig._distance - intro.shrine_distance) < 0.4,
		"intro: the camera zoomed in on the display (%.2f m, wanted %.2f)"
			% [_rig._distance, intro.shrine_distance])
	_expect(_rig._focus.distance_to(Vector3(shrine_pos.x, 0.0, shrine_pos.z)) < 0.3,
		"intro: the camera frames the display (off by %.2f m)"
			% _rig._focus.distance_to(Vector3(shrine_pos.x, 0.0, shrine_pos.z)))
	var card2: Image = await _shot("intro_card2_shrine")
	_expect(_mascot_pixels(card2) > 400, "intro: the two mascots are visible in the card-2 frame (%d px)"
		% _mascot_pixels(card2))

	# --- card 4: the reveal -----------------------------------------------
	var got_card4 := await _wait_for_card(intro, 3, 25.0)
	_expect(got_card4, "intro: card 4 (sales are up) comes up")
	_expect(bool(intro.horde_spawned), "intro: the horde is out for the reveal")
	_expect(_roamers.active_count() == int(intro.horde_count),
		"intro: %d customers crowd the windows (got %d)"
			% [int(intro.horde_count), _roamers.active_count()])
	var reveal: Image = await _shot("intro_card4_reveal")
	print("[preview] intro: %d of %d customers show as green in the card-4 frame"
		% [_visible_roamers(reveal), _roamers.roamers.size()])
	# The customers reach the glass while the card is up: wait for the leaning.
	var peeking := await _wait_for_peek(6, 10.0)
	_expect(peeking >= 6, "intro: the customers lean in at the glass (%d)" % peeking)
	var worst := 1.0e30
	var pair := ""
	for i in _roamers.roamers.size():
		for j in range(i + 1, _roamers.roamers.size()):
			var a := _roamers.roamers[i]
			var b := _roamers.roamers[j]
			if not a.is_peeking() or not b.is_peeking():
				continue
			var gap := a.global_position.distance_to(b.global_position)
			if gap < worst:
				worst = gap
				pair = "%s/%s" % [a.name, b.name]
	_expect(worst > 0.25, "intro: two peeking customers keep their distance (closest %s %.3f m)"
		% [pair, worst])
	var settled: Image = await _shot("intro_card4_peek")
	print("[preview] intro: %d of %d customers show as green in the settled card-4 frame"
		% [_visible_roamers(settled), _roamers.roamers.size()])

	# --- the skip clears the horde ----------------------------------------
	ui.cutscene.request_skip()
	var guard := 0.0
	while guard < 6.0 and bool(intro.running):
		await _wait_seconds(0.05)
		guard += 0.05
	_expect(not bool(intro.running), "intro: a skip ends the sequence")
	_expect(_roamers.active_count() == 0, "intro: the horde is cleared when the intro ends (%d out)"
		% _roamers.active_count())
	_expect(not bool(intro.horde_spawned), "intro: the reveal is marked as over")
	_expect(ui._top_bar.visible, "intro: skipping hands the UI back")

	# The natural end (no skip) clears the horde the same way.
	intro._spawn_horde()
	await _settle(2)
	_expect(_roamers.active_count() == 8, "intro: the horde can be put out again (%d)"
		% _roamers.active_count())
	intro._finish(null)
	await _settle(2)
	_expect(_roamers.active_count() == 0, "intro: the natural end clears the horde too")

	# --- the same horde again, outside the cutscene: the clean picture ----
	await _shoot_horde_windows(intro)

	# --- the fallback: a venue without a shrine ---------------------------
	_kitchen.load_layout("res://resources/layouts/demo_kitchen.txt")
	await _settle(2)
	_expect(_shrine_instance() == null, "intro: the demo kitchen ships without a shrine")
	var before := _rig._focus
	var skipped := await intro._shrine_beat(ui.cutscene)
	_expect(not skipped and _rig._focus.distance_to(before) < 0.01,
		"intro: without a shrine the card-2 beat is skipped, not aimed at nothing")


## The clean pictures of the reveal, with the intro's own horde (same count, same
## seed) put out again after the cutscene and the gameplay UI hidden:
##   horde_windows       from outside the busiest wall, where the wall hides
##                       itself and the crowd at the glass is the subject;
##   horde_reveal_frame  the intro's own card-4 framing, so the beat can be
##                       judged without the card and the letterbox over it.
func _shoot_horde_windows(intro: Node) -> void:
	var count := int(intro.horde_count)
	var seed := int(intro.horde_seed)
	_expect(_roamers.start_count(count, seed) == count,
		"horde: the intro's seed puts %d customers back out" % count)
	_roamers.peek_now()
	await _wait_for_peek(6, 10.0)
	var ui := _scene.get_node_or_null("UI")
	if ui != null and ui.has_method("_hide_gameplay_ui"):
		ui.call("_hide_gameplay_ui")

	var face := _busiest_facing_face(_all_faces())
	var centre := _face_centre(face)
	var normal: Vector3 = _roamers.faces[face]["normal"]
	_rig._yaw_deg = rad_to_deg(atan2(normal.x, normal.z))
	_rig.pitch_deg = 40.0
	await _rig.focus_world(centre + normal * 0.4, 8.5, 0.05)
	await _settle(4)
	_roamers.peek_now()
	await _wait_for_peek(5, 6.0)
	await _wait_seconds(0.6)
	var image := await _shot("horde_windows")
	_rig.pitch_deg = 50.0
	var green := _green_pixels(image)
	var leaning := 0
	for roamer in _roamers.roamers:
		if roamer.is_peeking():
			leaning += 1
	print("[preview] horde: %d of %d customers show as green at the wall, %d leaning"
		% [_visible_roamers(image), _roamers.roamers.size(), leaning])
	_expect(green > 60, "horde: the wall is crowded with glowing customers (%d green samples)" % green)
	_expect(leaning >= 5, "horde: the customers are leaning at the glass (%d)" % leaning)

	# The beat's own framing, clean.
	var door_cell: Vector2i = intro.call("_front_door_cell")
	_rig._yaw_deg = 0.0
	await _rig.focus_world(_kitchen.cell_to_world(door_cell), float(intro.door_distance), 0.05)
	await _settle(4)
	_roamers.peek_now()
	await _wait_for_peek(4, 6.0)
	var beat := await _shot("horde_reveal_frame")
	var seen := _visible_roamers(beat, 24)
	var beat_green := _green_pixels(beat)
	print("[preview] horde: %d of %d customers project onto green in the card-4 framing (%d green samples)"
		% [seen, _roamers.roamers.size(), beat_green])
	_expect(beat_green >= 20,
		"horde: the card-4 framing really shows the customers (%d green samples)" % beat_green)
	if ui != null and ui.has_method("_restore_game_ui"):
		ui.call("_restore_game_ui")


## Every face index (the crowd is spread over all of them by now).
func _all_faces() -> Array[int]:
	var out: Array[int] = []
	for i in _roamers.faces.size():
		out.append(i)
	return out


func _mascot_pixels(image: Image) -> int:
	var count := 0
	for y in range(0, image.get_height(), 2):
		for x in range(0, image.get_width(), 2):
			var family := _family(image.get_pixel(x, y))
			if family == "red" or family == "yellow":
				count += 1
	return count


## How many roamers project onto a green pixel in [param image]. The radius is
## generous because at the wide card-4 framing a customer is only a few pixels.
func _visible_roamers(image: Image, radius := 16) -> int:
	var seen := 0
	for roamer in _roamers.roamers:
		var screen := _cam.unproject_position(roamer.global_position + Vector3.UP * 0.6)
		if _greenest_around(image, screen, radius) > 0.12:
			seen += 1
	return seen


## Coarse colour family of a rendered pixel (same rules as the shrine preview).
func _family(c: Color) -> String:
	var hi := maxf(c.r, maxf(c.g, c.b))
	var lo := minf(c.r, minf(c.g, c.b))
	if hi < 0.16:
		return "black"
	if lo > 0.72 and hi - lo < 0.12:
		return "white"
	if c.r > 0.35 and c.r > c.g * 1.7 and c.r > c.b * 1.7:
		return "red"
	if c.r > 0.45 and c.g > 0.4 and c.b < c.g * 0.55 and c.r > c.b * 1.7:
		return "yellow"
	return "other"


## The venue's corporate shrine, if it has one (the intro's card-2 subject).
func _shrine_instance() -> FurnitureInstance:
	for inst in _kitchen.get_furniture_instances():
		if inst.def != null and inst.def.id == &"corporate_shrine":
			return inst
	return null


## Waits (up to [param timeout] seconds) for the intro to reach card [param index].
func _wait_for_card(intro: Node, index: int, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if not bool(intro.running):
			return false
		if int(intro.card_index) >= index and str(intro.beat) == "card":
			return true
		await get_tree().process_frame
	return false


func _disable_placer() -> void:
	var placer := _scene.find_child("PlaceController", true, false) as PlaceController
	if placer == null:
		return
	placer.set_process(false)
	placer.set_process_unhandled_input(false)
	for child in placer.get_children():
		if child is Node3D:
			(child as Node3D).visible = false


## Wall faces whose outward normal points towards the camera (a face pointing
## away hides its roamers behind 2.4 m of masonry at this pitch).
func _camera_facing_faces() -> Array[int]:
	var out: Array[int] = []
	var cam_pos := _cam.global_position
	for i in _roamers.faces.size():
		var face: Dictionary = _roamers.faces[i]
		var normal: Vector3 = face["normal"]
		if normal.dot((cam_pos - _face_centre(i)).normalized()) > 0.2:
			out.append(i)
	return out


## Of the camera-facing faces, the one with the most roamers near it.
func _busiest_facing_face(facing: Array[int]) -> int:
	var best := facing[0]
	var best_count := -1
	for i in facing:
		var count := 0
		for roamer in _roamers.roamers:
			if _nearest_face(roamer.global_position) == i:
				count += 1
		if count > best_count:
			best_count = count
			best = i
	return best


func _face_centre(index: int) -> Vector3:
	var patrol: Array[Vector3] = _roamers.faces[index]["patrol"]
	var centre := Vector3.ZERO
	for p in patrol:
		centre += p
	return centre / float(maxi(patrol.size(), 1))


## Which face a world position belongs to: the one with the nearest peek point.
func _nearest_face(pos: Vector3) -> int:
	var best := -1
	var best_dist := 1.0e30
	for i in _roamers.faces.size():
		var peeks: Array[Vector3] = _roamers.faces[i]["peeks"]
		for p in peeks:
			var dist := pos.distance_squared_to(p)
			if dist < best_dist:
				best_dist = dist
				best = i
	return best


# ---------------------------------------------------------------------------
# Screenshots + pixels
# ---------------------------------------------------------------------------

func _shot(label: String) -> Image:
	var image: Image = await _grab()
	var path := "%s/roamers_%s.png" % [OUT_DIR, label]
	var err := image.save_png(path)
	print("[preview] shot %s -> %s (err=%d)" % [label, path, err])
	_expect(err == OK, "shot %s saved" % label)
	# Unique copy right away: /tmp/opencode is shared with other agents.
	image.save_png("%s/roamers_keep_%s.png" % [OUT_DIR, label])
	return image


func _grab() -> Image:
	await _settle(3)
	await RenderingServer.frame_post_draw
	return _sub.get_texture().get_image()


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


func _wait_seconds(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## Waits (up to [param timeout] seconds) for [param want] roamers to be leaning.
func _wait_for_peek(want: int, timeout: float) -> int:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	var peeking := 0
	while Time.get_ticks_msec() < deadline:
		peeking = 0
		for roamer in _roamers.roamers:
			if roamer.is_peeking():
				peeking += 1
		if peeking >= want:
			return peeking
		await get_tree().process_frame
	return peeking


func _green_pixels(image: Image, threshold := 0.15) -> int:
	var count := 0
	for y in range(0, image.get_height(), 3):
		for x in range(0, image.get_width(), 3):
			if _greenness(image.get_pixel(x, y)) > threshold:
				count += 1
	return count


## The strongest "greenness" (g above both r and b) around a screen point.
func _greenest_around(image: Image, screen: Vector2, radius: int) -> float:
	var best := -1.0
	var cx := int(screen.x)
	var cy := int(screen.y)
	for y in range(cy - radius, cy + radius + 1, 2):
		for x in range(cx - radius, cx + radius + 1, 2):
			if x < 0 or y < 0 or x >= image.get_width() or y >= image.get_height():
				continue
			best = maxf(best, _greenness(image.get_pixel(x, y)))
	return best


func _greenness(color: Color) -> float:
	return color.g - maxf(color.r, color.b)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		_failures += 1
	print("[preview] %s - %s" % ["ok" if condition else "FAIL", label])
