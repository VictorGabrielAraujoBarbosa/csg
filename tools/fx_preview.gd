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
	"wash": 4.5,
	"burst": 5.0,
	"drop": 4.0,
	"delivered": 6.0,
	"place": 5.0,
	"window": 6.0,
	"eaten": 5.0,
}

## Camera pitch per moment: rising steam and splashes read better side-on.
const MOMENT_PITCH := {
	"steam": 30.0,
	"wash": 34.0,
	"burst": 42.0,
	"drop": 42.0,
	"delivered": 45.0,
	"place": 45.0,
	"window": 40.0,
	"eaten": 45.0,
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
var _max_playing := 0
var _max_sounding_paths: Array[String] = []
var _money_at_delivery := -1
var _reward_at_delivery := -1
var _eaten_pos := Vector3.ZERO


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
	# --- effects the sim cannot reach in this short run, triggered by hand ---
	# a placed piece: the layout diff fires the dust puff + place sound
	var cell := _find_free_cell()
	if cell.x > -900:
		kitchen.place_furniture(FurnitureCatalog.find(&"counter"), cell, 0)
		await _frames(3)
		await _capture("place", _cell_pos(cell) + Vector3(0.0, 0.25, 0.0), MOMENT_DIST["place"])
	# --- the horror, through the real path: start_mob breaks the windows and the
	# customers climb in and hunt the staff ---
	var broken := service.start_mob(3)
	print("[fx-preview] mob: %d broken edge(s)" % broken.size())
	await _frames(3)
	if not broken.is_empty():
		await _capture("window", _edge_pos(broken[0]), MOMENT_DIST["window"])
	else:
		# a map without windows: fire the stub by hand so the effect is still shown
		var edge := KitchenLayout.edge_key(Vector2i(4, -1), KitchenLayout.DIR_Z)
		service.window_broken.emit(edge)
		await _frames(3)
		await _capture("window", _edge_pos(edge), MOMENT_DIST["window"])
	var eaten_ticks := 0
	while _eaten_pos == Vector3.ZERO and eaten_ticks < 2000:
		service.run_ticks(5)
		eaten_ticks += 5
		await _frames(1)
		if _eaten_pos != Vector3.ZERO and not _done.has("eaten"):
			await _capture("eaten", _eaten_pos, MOMENT_DIST["eaten"])
	print("[fx-preview] mob ate a worker after %d ticks" % eaten_ticks)
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


func _capture_pending() -> void:
	for name in ["steam", "wash", "burst", "drop", "delivered"]:
		if _done.has(name) or not _pending.has(name):
			continue
		var pos: Vector3 = _pending[name]
		await _capture(name, pos, float(MOMENT_DIST.get(name, 8.0)))
	# audio is checked here, right after real events, so a short sound is caught
	var sounding := audio.sounding_paths()
	if sounding.size() > _max_playing:
		_max_playing = sounding.size()
		_max_sounding_paths = sounding


func _have_all() -> bool:
	for name in ["steam", "wash", "burst", "drop", "delivered"]:
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
		_pending["steam"] = _station_pos(job.station) + Vector3(0.0, 0.5, 0.0)
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
	if order != null:
		_reward_at_delivery = order.reward
	_money_at_delivery = service.orders.money


func _on_item_dropped(_item: WorldItem, cell: Vector2i) -> void:
	if not _pending.has("drop"):
		_pending["drop"] = _cell_pos(cell) + Vector3(0.0, 0.3, 0.0)


func _on_worker_consumed(worker: Worker) -> void:
	# keep the *first* one: that is the worker whose ooze burst fired
	if worker != null and is_instance_valid(worker) and _eaten_pos == Vector3.ZERO:
		_eaten_pos = worker.global_position + Vector3(0.0, 0.35, 0.0)


# ---------------------------------------------------------------------------
# Screenshots
# ---------------------------------------------------------------------------

func _capture(name: String, pos: Vector3, dist: float) -> void:
	if _done.has(name):
		return
	_done[name] = true
	_aim(pos, dist, float(MOMENT_PITCH.get(name, 45.0)))
	vfx.visible = false
	await _frames(2)
	var before := await _grab()
	vfx.visible = true
	await _frames(2)
	var after := await _grab()
	var diff := _diff(before, after)
	var err := after.save_png(OUT_PATH)
	var copy_path := COPY_DIR + COPY_PREFIX + name + ".png"
	DirAccess.copy_absolute(OUT_PATH, copy_path)
	# amplified difference image: shows *where* the effect changed the frame
	_diff_image(before, after).save_png(COPY_DIR + COPY_PREFIX + name + "_diff.png")
	_shots.append("%s: %d px differ (err %d)" % [name, diff, err])
	print("[fx-preview] shot '%s' at %s: %d pixels differ vs the same frame without FX -> %s" % [
		name, pos, diff, copy_path])


func _diff_only(pos: Vector3, dist: float) -> int:
	_aim(pos, dist)
	vfx.visible = false
	await _frames(2)
	var before := await _grab()
	vfx.visible = true
	await _frames(2)
	var after := await _grab()
	return _diff(before, after)


func _aim(pos: Vector3, dist: float, pitch := 45.0) -> void:
	if rig == null:
		return
	rig.pitch_deg = pitch
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
	print("  particles live/pooled: %d/%d (cap %d)" % [
		vfx.live_particle_count(), vfx.pooled_particle_count(), vfx.max_live_particles])
	print("  audio stats: ", audio.stats)
	print("  audio playing at peak: %d %s" % [_max_playing, _max_sounding_paths])
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
	_expect(_max_playing > 0, "audio: %d player(s) were sounding" % _max_playing)
	_expect(_done.has("delivered") and _reward_at_delivery > 0,
		"delivery: the order paid out (reward $%d)" % _reward_at_delivery)


func _expect(condition: bool, label: String) -> void:
	print("[fx-preview] %s - %s" % ["ok" if condition else "FAIL", label])
