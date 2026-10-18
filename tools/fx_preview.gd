extends Node
## Dev tool: instances the real game scene in an offscreen viewport, hangs the
## FX layer ([code]scenes/fx.tscn[/code]) under the world exactly like the game
## will, runs the real order pipeline in ticks ([code]sim_speed = 0[/code] +
## [method Service.run_ticks]) so genuine events fire, and saves screenshots of
## the effects that result. Run with:
##   godot --path . res://tools/fx_preview.tscn
##
## Every shot is saved to /tmp/opencode/fx_preview.png and copied immediately to
## /tmp/opencode/fx_S1_<moment>.png (other agents write into /tmp/opencode too).
## Each shot also compares the frame against the same frame with the FX layer
## hidden, so "the effect exists" is proven by pixels, not by hope.

const OUT_PATH := "/tmp/opencode/fx_preview.png"
const COPY_DIR := "/tmp/opencode/"
const COPY_PREFIX := "fx_S1_"
## The capture tool pins the demo kitchen so tests stay comparable; the FX
## preview does the same, so a half-built start map cannot stall the run.
const PINNED_LAYOUT := "res://resources/layouts/demo_kitchen.txt"

## Camera distance per captured moment.
const MOMENT_DIST := {
	"steam": 4.5,
	"fire": 3.2,
	"wash": 4.5,
	"burst": 5.0,
	"drop": 4.0,
	"delivered": 6.0,
	"served": 4.2,
	"carry": 1.7,
	"place": 5.0,
	"hover": 4.0,
	"window": 6.0,
	"eaten": 5.0,
	"bubble": 2.6,
	"horror": 14.0,
}

## Camera pitch per moment: rising steam and splashes read better side-on.
const MOMENT_PITCH := {
	"steam": 30.0,
	"fire": 38.0,
	"wash": 34.0,
	"burst": 42.0,
	"drop": 42.0,
	"delivered": 45.0,
	"served": 38.0,
	"carry": 45.0,
	"place": 45.0,
	"hover": 50.0,
	"window": 40.0,
	"eaten": 45.0,
	"bubble": 30.0,
	"horror": 42.0,
}

var sub: SubViewport
var world: SubViewport
var scene: Node
var kitchen: Kitchen
var service: Service
var rig: CameraRig
var vfx: Vfx
var audio: AudioBank

var _pending: Dictionary = {}   # moment name -> world position
var _done: Dictionary = {}
var _shots: Array[String] = []
var _frames_before: Dictionary = {}  # moment -> Image (FX hidden)
var _frames_after: Dictionary = {}   # moment -> Image (FX shown)
var _max_playing := 0
var _max_sounding_paths: Array[String] = []
var _money_at_delivery := -1
var _reward_at_delivery := -1
var _eaten_pos := Vector3.ZERO
var _ambient_before_horror := -1.0
var _ambient_during_horror := -1.0
var _ambient_after_horror := -1.0


func _ready() -> void:
	sub = SubViewport.new()
	sub.size = Vector2i(1280, 720)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sub)
	scene = load("res://scenes/main.tscn").instantiate()
	sub.add_child(scene)
	kitchen = scene.find_child("Kitchen", true, false) as Kitchen
	service = scene.find_child("Service", true, false) as Service
	rig = scene.find_child("CameraRig", true, false) as CameraRig
	_disable_controllers()
	# Hang the FX layer under the world, next to Service / Kitchen (the wiring
	# the game will use). Nothing in main.tscn is touched.
	world = scene.find_child("World", true, false) as SubViewport
	var fx: Node = (load("res://scenes/fx.tscn") as PackedScene).instantiate()
	world.add_child(fx)
	vfx = fx.get_node_or_null("Vfx") as Vfx
	audio = fx.get_node_or_null("AudioBank") as AudioBank
	print("[fx-preview] vfx=", vfx != null, " audio=", audio != null,
		" | audio driver=", AudioServer.get_driver_name(),
		" | world viewport=", world.size)
	if vfx == null or audio == null or service == null or kitchen == null:
		print("[fx-preview] FAIL - fx layer or scene wiring missing")
		get_tree().quit()
		return
	service.work_started.connect(_on_work_started)
	service.work_finished.connect(_on_work_finished)
	service.order_delivered.connect(_on_order_delivered)
	service.item_dropped.connect(_on_item_dropped)
	service.item_carried.connect(_on_item_carried)
	service.worker_consumed.connect(_on_worker_consumed)
	await _run()
	_report()
	get_tree().quit()


# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

func _run() -> void:
	await _frames(8)  # let the kitchen build and the UI settle
	service.sim_speed = 0.0
	service.orders.arrive_on_turn_in = false
	# pin the furnished demo kitchen (the capture tool does the same) and top up
	# anything it is missing, so the run always reaches a delivered order
	if FileAccess.file_exists(PINNED_LAYOUT):
		kitchen.layout_file = PINNED_LAYOUT
		await _frames(2)
	_ensure_kitchen()
	print("[fx-preview] kitchen: floors=%d furniture=%d instances=%d stations=%d workers=%d" % [
		kitchen.data.floors.size() if kitchen.data != null else -1,
		kitchen.data.furniture.size() if kitchen.data != null else -1,
		kitchen.get_furniture_instances().size(), service.stations.size(), service.workers.size()])
	_reset_world()
	# keep one order flowing at a time; turn-ins spawn the follow-up so the tray
	# pool runs dry and a real wash job happens (the sink effect)
	service.orders.arrive_on_turn_in = true
	service.request_order()
	print("[fx-preview] start: %s" % service.status_text())
	var noise := await _diff_only(Vector3(6.0, 0.0, 4.0), 12.0)
	print("[fx-preview] animation noise floor (FX hidden, 2 frames apart): %d px" % noise)
	var ticks := 0
	while ticks < 2600 and not _have_all():
		service.run_ticks(5)
		ticks += 5
		await _frames(2)
		await _capture_pending()
	print("[fx-preview] order pipeline ran %d ticks: %s" % [ticks, service.status_text()])
	# --- audio: the staff walked all through that run, and footsteps have no
	# signal to hang off, so the bank polls the walkers' cells itself ---
	await _footstep_checks()
	# --- effects the sim cannot reach in this short run, triggered by hand ---
	# the build-phase placement decal: drive the placer's hover by hand (its own
	# _process is off in this tool) and let the FX layer pick the state up
	await _capture_hover()
	# a placed piece: the layout diff fires the dust puff + place sound
	var cell := _find_free_cell()
	if cell.x > -900:
		kitchen.place_furniture(FurnitureCatalog.find(&"counter"), cell, 0)
		await _frames(3)
		await _capture("place", _cell_pos(cell) + Vector3(0.0, 0.25, 0.0), MOMENT_DIST["place"])
	# --- the horror, through the real path: start_mob breaks the windows and the
	# customers climb in and hunt the staff ---
	var look := scene.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if look != null and look.environment != null:
		_ambient_before_horror = look.environment.ambient_light_energy
	var broken := service.start_mob(3)
	print("[fx-preview] mob: %d broken edge(s)" % broken.size())
	# the flicker pulses, so sample the trough over a few frames rather than
	# trusting one lucky frame to be at the bottom of the pulse
	_ambient_during_horror = await _min_ambient(look, 20)
	print("[fx-preview] mob: ambient now %.3f (was %.3f)" % [_ambient_during_horror, _ambient_before_horror])
	if not broken.is_empty():
		await _capture("window", _edge_pos(broken[0]), MOMENT_DIST["window"])
	else:
		# a map without windows: fire the stub by hand so the effect is still shown
		var edge := KitchenLayout.edge_key(Vector2i(4, -1), KitchenLayout.DIR_Z)
		service.window_broken.emit(edge)
		await _frames(3)
		await _capture("window", _edge_pos(edge), MOMENT_DIST["window"])
	# the whole room dimmed and washed red (the light, not a particle, so this
	# one is a plain shot: hiding the FX node would not turn the flicker off)
	await _capture_horror("horror", _kitchen_centre(), MOMENT_DIST["horror"])
	# a panicking worker's "!" bubble: wait for the first one, then shoot it
	var bubble_ticks := 0
	while int(vfx.stats.get("panic_bubble", 0)) == 0 and bubble_ticks < 2000:
		service.run_ticks(2)
		bubble_ticks += 2
		await _frames(1)
	var fleer := _fleeing_worker()
	if not _done.has("bubble") and fleer != null:
		await _capture("bubble", fleer.global_position + Vector3(0.0, 1.05, 0.0), MOMENT_DIST["bubble"])
	var eaten_ticks := 0
	while _eaten_pos == Vector3.ZERO and eaten_ticks < 2000:
		service.run_ticks(5)
		eaten_ticks += 5
		await _frames(1)
		if _eaten_pos != Vector3.ZERO and not _done.has("eaten"):
			await _capture("eaten", _eaten_pos, MOMENT_DIST["eaten"])
	print("[fx-preview] mob ate a worker after %d ticks" % eaten_ticks)
	# the flicker has to put the light back exactly as it found it
	service.stop_mob()
	await _frames(3)
	if look != null and look.environment != null:
		_ambient_after_horror = look.environment.ambient_light_energy
	# --- audio proof ---
	var sounding := audio.sounding_paths()
	if sounding.size() > _max_playing:
		_max_playing = sounding.size()
		_max_sounding_paths = sounding
	if not service.workers.is_empty():
		audio.play_worker_consumed(service.workers[0].global_position)
		await _frames(1)
		sounding = audio.sounding_paths()
		print("[fx-preview] audio check: %d player(s) sounding: %s" % [sounding.size(), sounding])
		_expect(sounding.size() > 0, "audio: at least one player is playing right now")
	await _audio_bank_checks()


# ---------------------------------------------------------------------------
# Audio bank checks (footsteps, the horror bed, the music player)
# ---------------------------------------------------------------------------

## Footsteps have no signal to hang off: the bank polls each walker's cell and
## steps it when the cell changes. The order run above made the staff walk, so
## this is proof the poll fires (and the counts are the proof it is not silent).
func _footstep_checks() -> void:
	var steps := int(audio.stats.get("footstep", 0))
	print("[fx-preview] footsteps after the order run: %d step(s); log tail: %s" % [
		steps, audio.recent.slice(maxi(audio.recent.size() - 3, 0))])
	_expect(steps > 0, "audio: a footstep fired while workers walked (%d)" % steps)
	print("[fx-preview] player states after the run: %s" % [audio.player_states()])


## The horror bed (panic squeaks, growls, the heartbeat) and the music player.
## Called at the very end of the run, while the mob is still inside.
func _audio_bank_checks() -> void:
	print("---- audio bank: horror bed + music ----")
	var heavy := int(audio.stats.get("customer_footstep", 0))
	_expect(heavy > 0, "audio: customers stepped while they hunted (%d)" % heavy)
	var squeaks := int(audio.stats.get("panic_squeak", 0))
	_expect(squeaks > 0, "audio: fleeing workers squeaked (%d)" % squeaks)
	var growls := int(audio.stats.get("growl", 0))
	_expect(growls > 0, "audio: customers growled (%d)" % growls)
	# the heartbeat follows Service.mob_active on its own (polled every frame)
	print("[fx-preview] heartbeat: mob_active=%s bank=%s" % [
		service.mob_active, audio.is_heartbeat_active()])
	_expect(service.mob_active == audio.is_heartbeat_active(),
		"audio: the heartbeat state matches mob_active after the horror")
	# force the transition both ways so the coupling is proven even when the
	# mob already ate everyone (the bank reads the same flag the sim sets)
	service.mob_active = true
	await _wait_ms(80)
	_expect(audio.is_heartbeat_active(), "audio: the heartbeat starts with mob_active")
	var beats := int(audio.stats.get("heartbeat", 0))
	await _wait_ms(1500)
	var beats2 := int(audio.stats.get("heartbeat", 0))
	print("[fx-preview] heartbeat thumps over 1.5 s: %d -> %d | players: %s" % [
		beats, beats2, audio.player_states()])
	_expect(beats2 > beats, "audio: the heartbeat pulsed (%d -> %d thumps)" % [beats, beats2])
	service.stop_mob()
	await _wait_ms(80)
	_expect(not audio.is_heartbeat_active(), "audio: the heartbeat stops when the attack ends")
	# UI tells: the shop calls these on hover / on "cannot afford"
	var hover := audio.play_hover()
	var refused := audio.play_refused()
	await _frames(1)
	print("[fx-preview] UI tells: hover=%s refused=%s | players: %s" % [
		hover, refused, audio.player_states()])
	_expect(hover != null and refused != null, "audio: the shop hover / refused helpers play")
	_expect(int(audio.stats.get("hover", 0)) > 0 and int(audio.stats.get("refused", 0)) > 0,
		"audio: hover and refused are counted")
	# music: play -> duck -> release -> stop (the game UI decides *when*)
	var started := audio.play_music(&"build", 0.05)
	await _wait_ms(200)
	print("[fx-preview] music: started=%s playing=%s id='%s' path='%s' gain=%.1f dB" % [
		started, audio.is_music_playing(), audio.music_id(), audio.music_path(),
		audio.music_gain_db()])
	_expect(started and audio.is_music_playing(), "music: play_music('build') started the track")
	_expect(audio.music_path().get_file().begins_with("Airport"),
		"music: the id resolved to the build track (%s)" % audio.music_path().get_file())
	var loud := audio.music_gain_db()
	audio.duck(0.4, -12.0)
	await _wait_ms(400)
	var ducked := audio.music_gain_db()
	print("[fx-preview] music ducked: %.1f -> %.1f dB (is_ducked=%s)" % [
		loud, ducked, audio.is_ducked()])
	_expect(ducked < loud - 4.0, "music: duck() pulled the music down (%.1f -> %.1f dB)" % [loud, ducked])
	_expect(audio.is_ducked(), "music: is_ducked() reports the duck while it holds")
	await _wait_ms(1000)
	print("[fx-preview] music released: %.1f dB (target %.1f)" % [
		audio.music_gain_db(), audio.music_target_db()])
	_expect(absf(audio.music_gain_db() - loud) < 1.5,
		"music: the duck released back to %.1f dB" % loud)
	_expect(not audio.is_ducked(), "music: is_ducked() clears once the duck released")
	# switching tracks cross-fades; the game UI passes full paths, so prove both
	var switched := audio.play_music("res://assets/music/District%20Four - work.mp3", 0.15)
	await _wait_ms(500)
	print("[fx-preview] music switch: %s -> %s" % [switched, audio.music_path().get_file()])
	_expect(switched and audio.music_path().get_file().begins_with("District"),
		"music: switching by full path cross-faded to the work track")
	_expect(audio.music_gain_db() > loud - 2.0,
		"music: the new track faded back up (%.1f dB)" % audio.music_gain_db())
	audio.stop_music(0.05)
	await _wait_ms(300)
	print("[fx-preview] music after stop: playing=%s path='%s' | players: %s" % [
		audio.is_music_playing(), audio.music_path(), audio.player_states()])
	_expect(not audio.is_music_playing(), "music: stop_music() silenced the track")


## Waits on the wall clock, not on frames: the preview can run uncapped, and the
## audio bank is timed in real seconds.
func _wait_ms(ms: int) -> void:
	var until := Time.get_ticks_msec() + ms
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame


func _capture_pending() -> void:
	for name in ["steam", "fire", "carry", "wash", "burst", "drop", "delivered", "served"]:
		if _done.has(name) or not _pending.has(name):
			continue
		var pos: Vector3 = _pending[name]
		if name == "fire":
			# a close look at the burner from above and inside the room: the worker
			# stands in front of the stove and the row of counters blocks the sides
			await _capture("fire_close", pos + Vector3(0.0, 0.05, 0.0), 2.2, 62.0, 45.0)
		# points near a wall (the delivery counter, a dropped item) are shot from
		# the middle of the kitchen, so the camera stays inside the building
		var yaw := 45.0
		if name in ["drop", "delivered", "served"]:
			yaw = _yaw_towards(pos, _kitchen_centre())
		await _capture(name, pos, float(MOMENT_DIST.get(name, 8.0)), -1.0, yaw)
	# audio is checked here, right after real events, so a short sound is caught
	var sounding := audio.sounding_paths()
	if sounding.size() > _max_playing:
		_max_playing = sounding.size()
		_max_sounding_paths = sounding


func _have_all() -> bool:
	for name in ["steam", "fire", "carry", "wash", "burst", "drop", "delivered", "served"]:
		if not _done.has(name):
			return false
	return true


# ---------------------------------------------------------------------------
# Simulation event hooks (positions for the camera)
# ---------------------------------------------------------------------------

func _on_work_started(_worker: Worker, job: Job) -> void:
	if job == null or job.station == null:
		return
	if job.station.has_tag(&"cooking"):
		var top := _station_pos(job.station)
		_pending["steam"] = top + Vector3(0.0, 0.5, 0.0)
		# the flame sits on the burner, so it wants a lower, closer camera
		_pending["fire"] = top + Vector3(0.0, 0.3, 0.0)
	elif job.station.has_tag(&"washing"):
		_pending["wash"] = _station_pos(job.station) + Vector3(0.0, 0.4, 0.0)


func _on_work_finished(_worker: Worker, job: Job) -> void:
	if job == null or job.station == null or job.recipe == null or job.recipe.is_source:
		return
	# packing a tray is quick and dull; the interesting burst is a cooked dish
	if job.recipe.id == &"pack_order":
		return
	_pending["burst"] = _cell_pos(job.station.output_cell()) + Vector3(0.0, 0.4, 0.0)


func _on_order_delivered(order: Order, cell: Vector2i) -> void:
	_pending["delivered"] = _cell_pos(cell) + Vector3(0.0, 0.7, 0.0)
	_pending["served"] = _cell_pos(cell) + Vector3(0.0, 1.0, 0.0)
	if order != null:
		_reward_at_delivery = order.reward
	_money_at_delivery = service.orders.money


func _on_item_dropped(_item: WorldItem, cell: Vector2i) -> void:
	if not _pending.has("drop"):
		_pending["drop"] = _cell_pos(cell) + Vector3(0.0, 0.3, 0.0)


func _on_item_carried(_item: WorldItem, worker: Worker) -> void:
	if worker != null and is_instance_valid(worker):
		# aim at the hands: that is where the item (and its glow) rides
		var hands := worker.hands()
		var spot := hands.global_position if hands != null else worker.global_position
		_pending["carry"] = spot + Vector3(0.0, 0.25, 0.0)


func _on_worker_consumed(worker: Worker) -> void:
	# keep the *first* one: that is the worker whose ooze burst fired
	if worker != null and is_instance_valid(worker) and _eaten_pos == Vector3.ZERO:
		_eaten_pos = worker.global_position + Vector3(0.0, 0.35, 0.0)


# ---------------------------------------------------------------------------
# Screenshots
# ---------------------------------------------------------------------------

func _capture(name: String, pos: Vector3, dist: float, pitch := -1.0, yaw := 45.0) -> void:
	if _done.has(name):
		return
	_done[name] = true
	_aim(pos, dist, float(MOMENT_PITCH.get(name, 45.0)) if pitch < 0.0 else pitch, yaw)
	vfx.visible = false
	await _frames(2)
	var before := await _grab()
	vfx.visible = true
	await _frames(2)
	var after := await _grab()
	_frames_before[name] = before
	_frames_after[name] = after
	var diff := _diff(before, after)
	var err := after.save_png(OUT_PATH)
	var copy_path := COPY_DIR + COPY_PREFIX + name + ".png"
	DirAccess.copy_absolute(OUT_PATH, copy_path)
	# the same frame with the FX layer hidden, so a crop can be compared
	before.save_png(COPY_DIR + COPY_PREFIX + name + "_off.png")
	# amplified difference image: shows *where* the effect changed the frame
	_diff_image(before, after).save_png(COPY_DIR + COPY_PREFIX + name + "_diff.png")
	_shots.append("%s: %d px differ (err %d)" % [name, diff, err])
	print("[fx-preview] shot '%s' at %s: %d pixels differ vs the same frame without FX -> %s" % [
		name, pos, diff, copy_path])
	if name == "fire":
		for line in vfx.describe_loops():
			print("    [loops] ", line)


## The horror shot: the flicker is a pulse, so grab a handful of frames and keep
## the reddest one — a still frame has to catch the peak to show anything.
func _capture_horror(name: String, pos: Vector3, dist: float) -> void:
	if _done.has(name):
		return
	_done[name] = true
	_aim(pos, dist, float(MOMENT_PITCH.get(name, 45.0)))
	await _frames(2)
	var best := await _grab()
	var best_score := _redness(best)
	for i in 8:
		await _frames(1)
		var image := await _grab()
		var score := _redness(image)
		if score > best_score:
			best = image
			best_score = score
	var err := best.save_png(OUT_PATH)
	var copy_path := COPY_DIR + COPY_PREFIX + name + ".png"
	DirAccess.copy_absolute(OUT_PATH, copy_path)
	_shots.append("%s: plain shot, reddest of 9 frames (score %d, err %d)" % [name, best_score, err])
	print("[fx-preview] shot '%s' (horror, reddest frame) at %s: redness %d -> %s" % [
		name, pos, best_score, copy_path])


## The build-phase placement decal: the tool drives the placer's hover by hand
## (its own _process is disabled here) and the FX layer picks the state up.
func _capture_hover() -> void:
	var node := scene.find_child("PlaceController", true, false) as PlaceController
	if node == null:
		return
	var cell := _hover_spot()
	if cell.x < -900:
		return
	node.select_by_id(&"counter")
	if not node.has_selection:
		return
	node.set("_hover_cell", cell)
	node.set("_has_hover", true)
	node.set("_valid", true)
	node.set("rot_steps", 0)
	await _frames(4)
	print("[fx-preview] placer hover: def=%s cell=%s valid=%s" % [
		node.current_def(), cell, node.get("_valid")])
	for line in vfx.describe_hover():
		print("    [hover] ", line)
	await _capture("hover", _cell_pos(cell) + Vector3(0.0, 0.1, 0.0), MOMENT_DIST["hover"])
	# ... and the red variant of the same decal on an occupied spot
	node.set("_valid", false)
	await _frames(4)
	await _capture("hover_bad", _cell_pos(cell) + Vector3(0.0, 0.1, 0.0), MOMENT_DIST["hover"])
	node.set("_has_hover", false)
	node.clear_selection()


## A free floor cell near the middle of the kitchen: an open spot with a clear
## view, unlike the first cell the furniture search happens to find.
func _hover_spot() -> Vector2i:
	var def := FurnitureCatalog.find(&"counter")
	if def == null or kitchen.data == null:
		return Vector2i(-999, -999)
	var centre := _kitchen_centre()
	var best := Vector2i(-999, -999)
	var best_d := 1.0e9
	for cell: Vector2i in kitchen.data.floors:
		if not kitchen.can_place(def, cell, 0):
			continue
		var d := Vector2(cell).distance_to(Vector2(centre.x, centre.z))
		if d < best_d:
			best_d = d
			best = cell
	return best


func _fleeing_worker() -> Worker:
	for worker in service.workers:
		if is_instance_valid(worker) and worker.state == Worker.State.FLEE and not worker.eaten:
			return worker
	return null


## Lowest ambient energy over the next frames (the flicker is a pulse).
func _min_ambient(look: WorldEnvironment, frames: int) -> float:
	var lowest := 1.0e9
	for i in frames:
		await _frames(1)
		if look != null and look.environment != null:
			lowest = minf(lowest, look.environment.ambient_light_energy)
	return lowest if lowest < 1.0e8 else -1.0


## The yaw that puts the camera on the [param to] side of [param from]: a shot of
## something against a wall looks from inside the room instead of through it.
func _yaw_towards(from: Vector3, to: Vector3) -> float:
	var dir := Vector3(to.x - from.x, 0.0, to.z - from.z)
	if dir.length() < 0.5:
		return 45.0
	return rad_to_deg(atan2(dir.x, dir.z))


func _kitchen_centre() -> Vector3:
	if kitchen == null or kitchen.data == null or kitchen.data.floors.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	var count := 0
	for cell: Vector2i in kitchen.data.floors:
		sum += kitchen.cell_to_world(cell)
		count += 1
	if count == 0:
		return Vector3.ZERO
	return sum / float(count) + Vector3(0.0, 0.4, 0.0)


## How red a single frame looks (used to pick the reddest frame of the flicker).
## A graded score rather than a count, so it ranks frames instead of gating them.
func _redness(image: Image) -> int:
	var small := image.duplicate()
	small.resize(160, 90, Image.INTERPOLATE_BILINEAR)
	var score := 0.0
	for y in 90:
		for x in 160:
			var c: Color = small.get_pixel(x, y)
			score += clampf((c.r - maxf(c.g, c.b)) * 200.0, 0.0, 10.0)
	return int(score)


## Counts the pixels an effect pushed towards a colour, comparing the FX-on and
## FX-off frames pixel by pixel: a differential test, so a warm or green scene
## background cannot swamp the effect the way an absolute threshold does.
func _colour_gain(before: Image, after: Image, mode: String, gain := 0.08) -> int:
	var small_a := before.duplicate()
	var small_b := after.duplicate()
	small_a.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	small_b.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	var count := 0
	for y in 180:
		for x in 320:
			var a: Color = small_a.get_pixel(x, y)
			var b: Color = small_b.get_pixel(x, y)
			match mode:
				"warm":
					if (a.r - a.b) - (b.r - b.b) > gain and a.r > 0.4:
						count += 1
				"red":
					if (a.r - maxf(a.g, a.b)) - (b.r - maxf(b.g, b.b)) > gain:
						count += 1
				"green":
					if (a.g - maxf(a.r, a.b)) - (b.g - maxf(b.r, b.b)) > gain:
						count += 1
	return count


func _diff_only(pos: Vector3, dist: float) -> int:
	_aim(pos, dist)
	vfx.visible = false
	await _frames(2)
	var before := await _grab()
	vfx.visible = true
	await _frames(2)
	var after := await _grab()
	return _diff(before, after)


func _aim(pos: Vector3, dist: float, pitch := 45.0, yaw := 45.0) -> void:
	if rig == null:
		return
	rig.pitch_deg = pitch
	# always set the yaw: a moment that looks from behind a wall must not leak
	# its angle into the next shot
	rig.set("_yaw_deg", yaw)
	rig.focus_on(pos)
	rig.distance = dist
	rig._target_distance = dist
	rig._distance = dist
	rig._apply()


func _grab() -> Image:
	await RenderingServer.frame_post_draw
	# Grab the raw world viewport: the effects live in the 3D scene, and this
	# keeps the shot free of the player UI (which other agents are still building).
	if world != null:
		return world.get_texture().get_image()
	return sub.get_texture().get_image()


## Counts differing pixels on a downscaled copy (fast enough for GDScript).
func _diff(a: Image, b: Image) -> int:
	var small_a := a.duplicate()
	var small_b := b.duplicate()
	small_a.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	small_b.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	var count := 0
	for y in 180:
		for x in 320:
			var ca: Color = small_a.get_pixel(x, y)
			var cb: Color = small_b.get_pixel(x, y)
			if absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b) > 0.05:
				count += 1
	return count


## The same comparison as an image: black where nothing changed, bright where the
## effect landed (amplified 5x so a faint haze is visible at a glance).
func _diff_image(a: Image, b: Image) -> Image:
	var small_a := a.duplicate()
	var small_b := b.duplicate()
	small_a.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	small_b.resize(320, 180, Image.INTERPOLATE_BILINEAR)
	var out := Image.create(320, 180, false, Image.FORMAT_RGBA8)
	for y in 180:
		for x in 320:
			var ca: Color = small_a.get_pixel(x, y)
			var cb: Color = small_b.get_pixel(x, y)
			var d := absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			var level := clampf(d * 5.0, 0.0, 1.0)
			out.set_pixel(x, y, Color(level, level * 0.6, 0.0, 1.0))
	return out


func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _disable_controllers() -> void:
	# The player UI runs a scripted horror cutscene that drives the camera, adds
	# letterboxing and slows the sim: none of that belongs in a VFX preview, and
	# it would fight every camera aim below (the capture tool does the same with
	# --no-cutscene).
	var ui := scene.get_node_or_null("UI")
	if ui != null:
		ui.set("cutscene", null)
	for node_name in ["PlaceController", "MapPaintController"]:
		var node := scene.find_child(node_name, true, false)
		if node == null:
			continue
		node.set_process(false)
		node.set_process_unhandled_input(false)
		for child in node.get_children():
			if child is Node3D:
				(child as Node3D).visible = false


## Puts the kitchen back into a clean starting state (no jobs, no orders, a full
## tray pool) so the run is reproducible.
func _reset_world() -> void:
	service.orders.arrive_on_turn_in = false
	for worker in service.workers:
		worker.force_idle()
	for job in service.board.jobs:
		service.board.cancel(job, "reset")
	service.board.cleanup()
	for order in service.orders.orders:
		if order.is_active():
			order.state = Order.State.FAILED
	for item in service.items.items.duplicate():
		service.items.remove(item)
	service._seed_trays()


## The start kitchen ships as a shell the player builds up (and an authored map
## may still be missing a station), so the preview tops up whatever the burger
## line needs — everything goes through the normal
## [method Kitchen.place_furniture] API, which also re-syncs the service.
func _ensure_kitchen() -> void:
	var placed := 0
	var posts := 0
	while service.workers.size() + posts < 3 and posts < 3:
		if _place_around(&"worker_post", 1) == 0:
			break
		posts += 1
	placed += posts
	var needs: Dictionary = {
		&"cooking": &"stove",
		&"washing": &"sink",
		&"assembly": &"assembly_table",
		&"prep": &"counter",
		&"storage": &"fridge",
	}
	for tag: StringName in needs:
		if not _tag_reachable(tag):
			placed += _place_around(needs[tag], 1)
	_ensure_points()
	var reasons := service.can_serve(&"burger", [], [])
	print("[fx-preview] kitchen topped up with %d piece(s); gate reasons: %s" % [placed, reasons])
	if not reasons.is_empty():
		print("[fx-preview] FAIL - the kitchen cannot cook a burger: %s" % reasons)


## Is there a station with this tag a worker can actually walk up to?
func _tag_reachable(tag: StringName) -> bool:
	var from := _anchor_cell()
	for station in service.stations:
		if not station.has_tag(tag):
			continue
		var stand := Pathfinder.adjacent_walkable(kitchen, station.work_target(), from)
		if stand.x > -1000 and not Pathfinder.find_path(kitchen, from, stand).is_empty():
			return true
	return false


## The order intake / delivery points have to be reachable, or nothing flows:
## move them to a free cell if the authored map put one in a dead corner.
func _ensure_points() -> void:
	for pair in [[&"intake", KitchenLayout.PointKind.PICKUP], [&"delivery", KitchenLayout.PointKind.DELIVERY]]:
		var tag: StringName = pair[0]
		var kind: int = pair[1]
		if _tag_reachable(tag):
			continue
		var old := _station_cell(tag)
		var spot := _point_spot()
		if spot.x < -900:
			continue
		if old.x > -900:
			kitchen.clear_point(old)
		kitchen.paint_point(spot, kind)
		print("[fx-preview] moved the %s point to %s" % [tag, spot])


func _station_cell(tag: StringName) -> Vector2i:
	for station in service.stations:
		if station.has_tag(tag):
			return station.origin()
	return Vector2i(-999, -999)


func _point_spot() -> Vector2i:
	var from := _anchor_cell()
	if kitchen.data == null:
		return Vector2i(-999, -999)
	for cell: Vector2i in kitchen.data.floors:
		if kitchen.furniture_at(cell) != null or kitchen.data.points.has(cell):
			continue
		var stand := Pathfinder.adjacent_walkable(kitchen, cell, from)
		if stand.x > -1000 and not Pathfinder.find_path(kitchen, from, stand).is_empty():
			return cell
	return Vector2i(-999, -999)


## Places up to [param count] pieces of [param id] on free cells that a worker
## can stand next to and reach from the kitchen anchor.
func _place_around(id: StringName, count: int) -> int:
	var def := FurnitureCatalog.find(id)
	if def == null:
		return 0
	var from := _anchor_cell()
	var placed := 0
	for cell: Vector2i in _free_cells(def, from):
		if placed >= count:
			break
		if kitchen.place_furniture(def, cell, 0) != null:
			placed += 1
	return placed


func _free_cells(def: FurnitureDef, from: Vector2i, limit := 8) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if kitchen.data == null:
		return out
	for cell: Vector2i in kitchen.data.floors:
		if out.size() >= limit:
			break
		if not kitchen.can_place(def, cell, 0):
			continue
		var stand := Pathfinder.adjacent_walkable(kitchen, cell, from)
		if stand.x < -1000 or Pathfinder.find_path(kitchen, from, stand).is_empty():
			continue
		out.append(cell)
	return out


## A walkable cell the whole kitchen hangs off: next to the order intake, or a
## worker post, or any floor cell.
func _anchor_cell() -> Vector2i:
	for station in service.stations:
		if station.has_tag(&"intake"):
			var stand := Pathfinder.adjacent_walkable(kitchen, station.work_target(), Vector2i.ZERO)
			if stand.x > -1000:
				return stand
	if not service.workers.is_empty():
		return service.workers[0].spawn_cell
	if kitchen.data != null:
		for cell: Vector2i in kitchen.data.floors:
			if kitchen.is_walkable(cell):
				return cell
	return Vector2i.ZERO


func _find_free_cell() -> Vector2i:
	var def := FurnitureCatalog.find(&"counter")
	if def == null:
		return Vector2i(-999, -999)
	var cells := _free_cells(def, _anchor_cell())
	return cells[0] if not cells.is_empty() else Vector2i(-999, -999)


func _cell_pos(cell: Vector2i) -> Vector3:
	return kitchen.cell_to_world(cell) + Vector3(0.0, kitchen.surface_height(cell), 0.0)


func _station_pos(station: StationInstance) -> Vector3:
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


func _edge_pos(edge: Vector3i) -> Vector3:
	var pos := Vector3(float(edge.x), 0.0, float(edge.y))
	if edge.z == KitchenLayout.DIR_X:
		pos.x += 0.5
	else:
		pos.z += 0.5
	return pos + Vector3(0.0, 1.0, 0.0)


func _report() -> void:
	print("---- fx preview report ----")
	print("  shots: ", _shots)
	print("  vfx stats: ", vfx.stats)
	print("  vfx throttled: ", vfx.throttled)
	print("  particles live/pooled: %d/%d (cap %d), loops=%d, flame lamps=%d" % [
		vfx.live_particle_count(), vfx.pooled_particle_count(), vfx.max_live_particles,
		vfx.loop_count(), vfx.light_count()])
	print("  audio stats: ", audio.stats)
	print("  audio playing at peak: %d %s" % [_max_playing, _max_sounding_paths])
	print("  audio log (last 8):")
	for line in audio.recent.slice(maxi(audio.recent.size() - 8, 0)):
		print("    ", line)
	print("  horror ambient: before=%.3f during=%.3f after=%.3f" % [
		_ambient_before_horror, _ambient_during_horror, _ambient_after_horror])
	print("  last vfx bursts:")
	for line in vfx.recent.slice(maxi(vfx.recent.size() - 12, 0)):
		print("    ", line)
	if _reward_at_delivery >= 0:
		print("  delivery: order paid $%d, purse now $%d" % [_reward_at_delivery, _money_at_delivery])
	_expect(vfx.stats.get("steam", 0) > 0, "vfx: a cooking job started steam")
	_expect(vfx.stats.get("wash", 0) > 0, "vfx: a washing job started suds")
	_expect(vfx.stats.get("sparkle", 0) > 0, "vfx: producing fired the sparkle burst")
	_expect(vfx.stats.get("confetti", 0) > 0, "vfx: a delivery fired the confetti")
	_expect(vfx.stats.get("money_label", 0) > 0, "vfx: a delivery spawned the +$ label")
	_expect(vfx.stats.get("shards", 0) > 0, "vfx: window_broken fired the shard burst")
	_expect(vfx.stats.get("ooze", 0) > 0, "vfx: worker_consumed fired the ooze puff")
	_expect(vfx.pooled_particle_count() <= vfx.max_live_particles,
		"vfx: the particle pool stayed inside its cap (%d)" % vfx.max_live_particles)
	_expect(vfx.loop_count() == 0,
		"vfx: every station loop stopped when the kitchen went quiet (%d left)" % vfx.loop_count())
	_expect(vfx.light_count() == 0,
		"vfx: no flame lamp is left burning (%d left)" % vfx.light_count())
	_expect(_max_playing > 0, "audio: %d player(s) were sounding" % _max_playing)
	_expect(_done.has("delivered") and _reward_at_delivery > 0,
		"delivery: the order paid out (reward $%d)" % _reward_at_delivery)
	# --- the new effects ---
	_expect(vfx.stats.get("fire", 0) > 0, "vfx: a cooking job lit the stove flame")
	_expect(vfx.stats.get("fire_shimmer", 0) > 0, "vfx: the heat shimmer started with the flame")
	_check_fire_pixels()
	_expect(vfx.stats.get("panic_bubble", 0) > 0, "vfx: a fleeing worker raised a '!' bubble")
	_check_bubble_pixels()
	_expect(vfx.stats.get("served_stamp", 0) > 0, "vfx: a delivery stamped SERVED")
	_check_stamp_pixels()
	_expect(vfx.stats.get("horror_flicker", 0) > 0, "vfx: the mob started the light flicker")
	_expect(_ambient_during_horror >= 0.0 and _ambient_during_horror < _ambient_before_horror - 0.02,
		"horror: the ambient dimmed while the mob was inside (%.3f -> %.3f)" % [
			_ambient_before_horror, _ambient_during_horror])
	_expect(_ambient_after_horror >= 0.0 and absf(_ambient_after_horror - _ambient_before_horror) < 0.001,
		"horror: the original ambient came back (%.3f -> %.3f)" % [
			_ambient_before_horror, _ambient_after_horror])
	_expect(vfx.stats.get("carry_highlight", 0) > 0, "vfx: a carried item got its glow")
	_check_carry_pixels()
	_expect(vfx.stats.get("hover_glow", 0) > 0, "vfx: the placement hover lit its decal")


func _check_fire_pixels() -> void:
	if not _frames_after.has("fire") or not _frames_before.has("fire"):
		_expect(false, "pixels: the fire shot was taken")
		return
	var warm := _colour_gain(_frames_before["fire"], _frames_after["fire"], "warm", 0.06)
	_expect(warm > 20,
		"pixels: the flame and its light warm up %d pixels of the frame" % warm)


## The carried item's glow is soft, so the bar is low: it only has to push a few
## pixels of the frame warmer than the same frame without the FX layer.
func _check_carry_pixels() -> void:
	if not _frames_after.has("carry") or not _frames_before.has("carry"):
		_expect(false, "pixels: the carry shot was taken")
		return
	var warm := _colour_gain(_frames_before["carry"], _frames_after["carry"], "warm", 0.04)
	_expect(warm > 8, "pixels: the carried item's glow warms %d pixels" % warm)


func _check_bubble_pixels() -> void:
	if not _frames_after.has("bubble") or not _frames_before.has("bubble"):
		_expect(false, "pixels: the bubble shot was taken")
		return
	var red := _colour_gain(_frames_before["bubble"], _frames_after["bubble"], "red", 0.1)
	_expect(red > 2, "pixels: the '!' mark reddens %d pixels of the frame" % red)


func _check_stamp_pixels() -> void:
	if not _frames_after.has("served") or not _frames_before.has("served"):
		_expect(false, "pixels: the served shot was taken")
		return
	var green := _colour_gain(_frames_before["served"], _frames_after["served"], "green", 0.06)
	_expect(green > 20, "pixels: the SERVED stamp greens %d pixels of the frame" % green)


func _expect(condition: bool, label: String) -> void:
	print("[fx-preview] %s - %s" % ["ok" if condition else "FAIL", label])
