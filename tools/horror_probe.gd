extends Node
## Dev probe for the horror fixes: the customers' ghost pathing and the intro's
## "Enter to skip" hint. Run the assertions headless:
##
##   /home/victor/Godot_v4.7.2-stable_linux.x86_64 --headless --path . \
##     res://tools/horror_probe.tscn
##
## or with a display to also write the two screenshots (a customer walking over
## a counter toward a worker, and the intro with its skip hint):
##
##   DISPLAY=:1 ... res://tools/horror_probe.tscn -- --shot-ghost --shot-intro
##
## Exits with code 1 when a check fails. The capture suite owns the game's own
## assertions; this tool owns the two fixes it cannot see from the demo map.

const SHOT_DIR := "/tmp/opencode"
const GHOST_SHOT := SHOT_DIR + "/horror_probe_ghost.png"
const INTRO_SHOT := SHOT_DIR + "/horror_probe_intro.png"

var _checks := 0
var _fails := 0
var _eaten := 0
## True when a real display is attached, so rendered pixels can be sampled.
var _can_render := false


func _ready() -> void:
	_can_render = DisplayServer.get_name() != "headless"
	var args := OS.get_cmdline_user_args()
	await _test_ghost_rules()
	await _test_solid_piece()
	await _test_customer_over_counter()
	await _test_customer_chases_moving_worker()
	await _test_customer_without_prey()
	await _test_customer_with_unreachable_prey()
	await _test_ghost_entry()
	await _test_intro_hint()
	if "--shot-ghost" in args:
		await _stage_ghost_shot()
	if "--shot-intro" in args:
		await _stage_intro_shot()
	print("[probe] %s (%d checks, %d failures)" % [
		"FAIL" if _fails > 0 else "ok", _checks, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


# ---------------------------------------------------------------------------
# The ghost rule (Kitchen) and the search (Pathfinder)
# ---------------------------------------------------------------------------

## A wall blocks the workers and not the ghost, the default call is still the
## strict search, and `avoid` still works positionally.
func _test_ghost_rules() -> void:
	var strip := KitchenLayout.new()
	for x in 5:
		strip.set_floor(Vector2i(x, 0), KitchenLayout.Floor.TILE)
	strip.set_wall(Vector2i(2, 0), KitchenLayout.DIR_X, KitchenLayout.Wall.SOLID)
	var kitchen := _make_kitchen(strip)
	_expect(kitchen.is_walkable(Vector2i(2, 0)) and kitchen.is_walkable(Vector2i(3, 0)),
		"rules: the corridor is floor for the workers")
	_expect(not kitchen.can_cross(Vector2i(2, 0), Vector2i(3, 0)),
		"rules: the closed wall stops a worker")
	_expect(kitchen.walkable_for_ghost(Vector2i(2, 0)) and kitchen.walkable_for_ghost(Vector2i(3, 0)),
		"rules: every floor cell is walkable for a ghost")
	_expect(not kitchen.walkable_for_ghost(Vector2i(0, 1)),
		"rules: a cell with no floor is not walkable for a ghost")
	_expect(kitchen.can_cross_ghost(Vector2i(2, 0), Vector2i(3, 0)),
		"rules: a ghost crosses the closed wall")
	_expect(not kitchen.can_cross_ghost(Vector2i(2, 0), Vector2i(2, 2)),
		"rules: a ghost only crosses to a neighbour")
	var strict := Pathfinder.find_path(kitchen, Vector2i(0, 0), Vector2i(4, 0))
	_expect(strict.is_empty(), "rules: a worker has no way past the closed wall")
	var ghost := Pathfinder.find_path(kitchen, Vector2i(0, 0), Vector2i(4, 0), [], true)
	_expect(ghost == _straight_line(5), "rules: a ghost walks straight through it (%s)" % str(ghost))
	_expect(Pathfinder.find_path(kitchen, Vector2i(0, 0), Vector2i(4, 0), []) == strict,
		"rules: the default call is still the strict search")
	kitchen.queue_free()
	# `avoid` (the fourth argument) is untouched: a worker steps around busy tiles.
	var room := KitchenLayout.new()
	for x in 5:
		for z in 3:
			room.set_floor(Vector2i(x, z), KitchenLayout.Floor.TILE)
	var open_kitchen := _make_kitchen(room)
	var busy: Array[Vector2i] = [Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]
	var detour := Pathfinder.find_path(open_kitchen, Vector2i(0, 0), Vector2i(4, 0), busy)
	_expect(detour.size() > 5 and not detour.has(Vector2i(2, 0)),
		"rules: the avoid list still routes around busy tiles (%s)" % str(detour))
	open_kitchen.queue_free()


## The same corridor with a solid counter in the middle: the workers are stuck,
## the ghost walks over it.
func _test_solid_piece() -> void:
	var strip := KitchenLayout.new()
	for x in 5:
		strip.set_floor(Vector2i(x, 0), KitchenLayout.Floor.TILE)
	var kitchen := _make_kitchen(strip)
	var counter := FurnitureCatalog.find(&"counter")
	_expect(counter != null and counter.solid, "piece: the catalog still has a solid counter")
	if counter == null:
		kitchen.queue_free()
		return
	_expect(kitchen.place_furniture(counter, Vector2i(2, 0), 0, {}, false) != null,
		"piece: the counter is placed in the corridor")
	_expect(not kitchen.is_walkable(Vector2i(2, 0)), "piece: the counter blocks the workers")
	_expect(kitchen.walkable_for_ghost(Vector2i(2, 0)), "piece: the counter does not block a ghost")
	_expect(Pathfinder.find_path(kitchen, Vector2i(0, 0), Vector2i(4, 0)).is_empty(),
		"piece: a worker cannot pass the counter")
	var ghost := Pathfinder.find_path(kitchen, Vector2i(0, 0), Vector2i(4, 0), [], true)
	_expect(ghost == _straight_line(5), "piece: a ghost walks over it (%s)" % str(ghost))
	kitchen.queue_free()


# ---------------------------------------------------------------------------
# The customer itself (a real Service, real workers)
# ---------------------------------------------------------------------------

## A customer on one side of a counter, a worker on the other. The worker's cell
## is unreachable under the strict rules and the customer still eats it — this
## is the stall the author hit. Runs through the real mob tick (Service.tick_once
## with the mob active), so it is the shipped loop, not a private one.
func _test_customer_over_counter() -> void:
	var layout := KitchenLayout.new()
	for x in 5:
		layout.set_floor(Vector2i(x, 0), KitchenLayout.Floor.TILE)
	layout.furniture.append({"id": &"worker_post", "cell": Vector2i(4, 0), "steps": 0, "tints": {}})
	var kitchen := _make_kitchen(layout)
	var counter := FurnitureCatalog.find(&"counter")
	if counter != null:
		kitchen.place_furniture(counter, Vector2i(2, 0), 0, {}, false)
	var service := _make_service(kitchen)
	_expect(service.workers.size() == 1, "hunt: the post staffs one worker")
	if service.workers.is_empty():
		_cleanup(service, kitchen)
		return
	var worker: Worker = service.workers[0]
	_expect(worker.cell == Vector2i(4, 0), "hunt: the worker stands at its post")
	_expect(Pathfinder.find_path(kitchen, Vector2i(0, 0), worker.cell).is_empty(),
		"hunt: the worker is unreachable under the strict rules")
	_spawn_customer(service, Vector2i(0, 0))
	service.mob_active = true
	var customer: Customer = service.customers[0]
	var crossed := false
	var ticks := 0
	while ticks < 60 and _eaten == 0:
		service.tick_once()
		ticks += 1
		if customer.cell == Vector2i(2, 0):
			crossed = true
	_expect(crossed, "hunt: the customer stepped onto the counter cell")
	_expect(_eaten == 1, "hunt: it reached and ate the worker (%d ticks)" % ticks)
	_expect(worker.eaten, "hunt: the worker is gone")
	_expect(service.workers.is_empty(), "hunt: no staff left standing")
	_cleanup(service, kitchen)


## The prey moves: the hunt must re-plan as the target changes cell and still
## catch it. The prey is moved by hand — Service does not tick workers while the
## mob is inside (it only re-plans their flight), so this is the customer's own
## re-planning under test, not the staff's walking.
func _test_customer_chases_moving_worker() -> void:
	var layout := KitchenLayout.new()
	for x in 24:
		layout.set_floor(Vector2i(x, 0), KitchenLayout.Floor.TILE)
	layout.furniture.append({"id": &"worker_post", "cell": Vector2i(4, 0), "steps": 0, "tints": {}})
	var kitchen := _make_kitchen(layout)
	var service := _make_service(kitchen)
	_expect(service.workers.size() == 1, "chase: the post staffs one worker")
	if service.workers.is_empty():
		_cleanup(service, kitchen)
		return
	var worker: Worker = service.workers[0]
	var customer := _spawn_customer(service, Vector2i(0, 0))
	var moves := 0
	var ticks := 0
	while ticks < 200 and _eaten == 0:
		customer.tick(ticks)
		ticks += 1
		# Every third tick the prey slips three cells further down the corridor.
		if ticks % 3 == 0 and _eaten == 0 and worker.cell.x + 3 < 24:
			worker.cell += Vector2i(3, 0)
			moves += 1
	_expect(moves > 1, "chase: the prey really moved (%d times)" % moves)
	_expect(_eaten == 1, "chase: the customer caught it (%d ticks)" % ticks)
	_expect(customer.repaths > 1, "chase: the hunt re-planned as the prey moved (%d)" % customer.repaths)
	_cleanup(service, kitchen)


## Nobody left to eat: the customer stands still and never re-plans.
func _test_customer_without_prey() -> void:
	var layout := KitchenLayout.new()
	for x in 5:
		layout.set_floor(Vector2i(x, 0), KitchenLayout.Floor.TILE)
	var kitchen := _make_kitchen(layout)
	var service := _make_service(kitchen)
	_expect(service.workers.is_empty(), "no-prey: the probe kitchen has no staff")
	var customer := _spawn_customer(service, Vector2i(0, 0))
	for i in 200:
		customer.tick(i)
	_expect(customer.cell == Vector2i(0, 0), "no-prey: the customer stays put")
	_expect(customer.repaths == 0, "no-prey: it never plans an empty hunt (%d re-plans)" % customer.repaths)
	_expect(customer.state == Customer.State.HUNT, "no-prey: it stays in the hunt state")
	_cleanup(service, kitchen)


## A prey on a floor island the customer's floor does not touch: no route even
## for a ghost. The customer must hold its ground and retry on a cooldown.
func _test_customer_with_unreachable_prey() -> void:
	var layout := KitchenLayout.new()
	for x: int in [0, 1, 4, 5]:
		layout.set_floor(Vector2i(x, 0), KitchenLayout.Floor.TILE)
	layout.furniture.append({"id": &"worker_post", "cell": Vector2i(5, 0), "steps": 0, "tints": {}})
	var kitchen := _make_kitchen(layout)
	var service := _make_service(kitchen)
	_expect(Pathfinder.find_path(kitchen, Vector2i(0, 0), Vector2i(5, 0), [], true).is_empty(),
		"island: even a ghost has no route across the gap")
	var customer := _spawn_customer(service, Vector2i(0, 0))
	for i in 300:
		customer.tick(i)
	_expect(customer.cell == Vector2i(0, 0), "island: the customer holds its ground")
	_expect(customer.repaths >= 2 and customer.repaths <= 300 / Customer.REPATH_TICKS + 2,
		"island: it retries on a cooldown, not every tick (%d in 300 ticks)" % customer.repaths)
	_cleanup(service, kitchen)


## A customer dropped outside the building (the service falls back to the cell
## beyond the wall when a piece covers the window's inside cell). A ghost may
## start off the floor and still walks in; the customer itself snaps onto the
## nearest floor cell so it never stands in the void.
func _test_ghost_entry() -> void:
	var layout := KitchenLayout.new()
	for x: int in [2, 3, 4]:
		layout.set_floor(Vector2i(x, 0), KitchenLayout.Floor.TILE)
	layout.furniture.append({"id": &"worker_post", "cell": Vector2i(4, 0), "steps": 0, "tints": {}})
	var kitchen := _make_kitchen(layout)
	var service := _make_service(kitchen)
	_expect(not kitchen.walkable_for_ghost(Vector2i(0, 0)), "entry: the drop cell has no floor")
	var from_void := Pathfinder.find_path(kitchen, Vector2i(1, 0), Vector2i(4, 0), [], true)
	_expect(from_void.size() == 4 and from_void[0] == Vector2i(1, 0),
		"entry: a ghost path may start off the floor (%s)" % str(from_void))
	_expect(Pathfinder.find_path(kitchen, Vector2i(1, 0), Vector2i(4, 0)).is_empty(),
		"entry: a worker path still refuses to start off the floor")
	var customer := _spawn_customer(service, Vector2i(0, 0))
	_expect(customer.cell == Vector2i(2, 0),
		"entry: the customer snaps to the nearest floor cell (%s)" % str(customer.cell))
	var ticks := 0
	while ticks < 40 and _eaten == 0:
		customer.tick(ticks)
		ticks += 1
	_expect(_eaten == 1, "entry: it still reaches the worker (%d ticks)" % ticks)
	_cleanup(service, kitchen)


# ---------------------------------------------------------------------------
# The intro's skip hint
# ---------------------------------------------------------------------------

## Up for the whole intro, saying exactly what the director accepts, and gone
## when the sequence ends.
func _test_intro_hint() -> void:
	var sub := _new_viewport()
	var scene := _new_main_scene(sub)
	await _frames(3)
	var ui := scene.get_node_or_null("UI")
	var intro: IntroSequence = ui.get_node_or_null("Intro") if ui != null else null
	var director: CutsceneDirector = ui.get_node_or_null("Cutscene") if ui != null else null
	_expect(intro != null and director != null, "hint: the main scene has the intro and the director")
	if intro == null or director == null:
		return
	_expect(director.skip_requires_enter, "hint: the director's skip is Enter-only (the hint's premise)")
	_expect(intro.skip_hint_label() == null, "hint: nothing is up before the sequence starts")
	# The text follows the rule instead of being hardcoded: a director that
	# accepts any key must not advertise Enter.
	director.skip_requires_enter = false
	_expect(intro.skip_hint_text() == "any key to skip",
		"hint: an any-key director is not advertised as Enter ('%s')" % intro.skip_hint_text())
	director.skip_requires_enter = true
	_expect(intro.skip_hint_text() == "Enter to skip", "hint: the Enter-only director says so")
	if ui.has_method("start_game"):
		ui.call("start_game", false)  # the shipped entry point: it plays the intro
	else:
		intro.play()
	await _wait(0.4)
	var label := intro.skip_hint_label()
	_expect(label != null and label.is_visible_in_tree(), "hint: the hint is up while the intro runs")
	if label == null:
		return
	_expect(label.text == "Enter to skip", "hint: it says exactly 'Enter to skip' (got '%s')" % label.text)
	_expect(label.text == intro.skip_hint_text(), "hint: the text follows the director's rule")
	_expect(intro.running, "hint: the intro is still running")
	if _can_render:
		await RenderingServer.frame_post_draw
		var img := sub.get_texture().get_image()
		var bright := -1.0
		if img != null:
			bright = _brightest(img, _rect_of(label))
		_expect(bright > 0.7, "hint: the hint's text is really rendered (max luminance %.2f)" % bright)
	else:
		print("[probe] note: headless run — the hint's pixels were not sampled")
	# The hint must disappear when the sequence ends.
	director.request_skip()
	var guard := 0.0
	while guard < 12.0 and intro.running:
		await _wait(0.05)
		guard += 0.05
	_expect(not intro.running, "hint: the skip ends the sequence (%.2fs)" % guard)
	_expect(not label.visible, "hint: the hint is hidden afterwards")
	sub.queue_free()


# ---------------------------------------------------------------------------
# Screenshots
# ---------------------------------------------------------------------------

## The customer crossing the counter at (5, 4) of the shipped start map, with a
## worker waiting on the far side.
func _stage_ghost_shot() -> void:
	var sub := _new_viewport()
	var scene := _new_main_scene(sub)
	await _frames(3)
	var ui := scene.get_node_or_null("UI")
	var kitchen := scene.find_child("Kitchen", true, false) as Kitchen
	var service := scene.find_child("Service", true, false) as Service
	var rig := scene.find_child("CameraRig", true, false) as CameraRig
	_expect(kitchen != null and service != null, "shot: the main scene has a kitchen and a service")
	if kitchen == null or service == null:
		return
	if ui != null and ui.has_method("start_game"):
		ui.call("start_game", true)  # straight to the build phase, no menu
	await _frames(3)
	if ui != null and ui.has_method("_hide_gameplay_ui"):
		ui.call("_hide_gameplay_ui")  # the kitchen alone, like the horror beats
	service.sim_speed = 0.0
	# Keep one worker, on the far side of the counter at (5, 4).
	for worker: Worker in service.workers.duplicate():
		worker.eaten = true
		worker.despawn()
	service.workers.clear()
	var worker := Worker.new()
	service.add_child(worker)
	worker.setup(service, Vector2i(5, 5), service.worker_tint)
	service.workers.append(worker)
	_expect(kitchen.has_floor(Vector2i(5, 5)), "shot: the worker's cell is floor")
	_expect(not kitchen.is_walkable(Vector2i(5, 4)), "shot: the counter cell blocks the workers")
	_expect(kitchen.walkable_for_ghost(Vector2i(5, 4)), "shot: the counter cell is open to the ghost")
	var customer := _spawn_customer(service, Vector2i(5, 3))
	var ticks := 0
	while customer.cell != Vector2i(5, 4) and ticks < 20:
		customer.tick(ticks)
		ticks += 1
	_expect(customer.cell == Vector2i(5, 4), "shot: the customer is on the counter cell")
	_expect(kitchen.surface_height(Vector2i(5, 4)) > 0.3,
		"shot: the counter has a surface to stand on (%.2f m)" % kitchen.surface_height(Vector2i(5, 4)))
	if rig != null:
		rig.start_yaw_deg = 90.0
		rig._yaw_deg = 90.0
		rig.pitch_deg = 24.0
		rig.focus_world(Vector3(5.0, 0.0, 4.6), 4.2, 0.0)
	await _frames(40)
	await RenderingServer.frame_post_draw
	var img := sub.get_texture().get_image()
	_expect(img != null, "shot: the frame rendered")
	var cam := scene.find_child("Camera3D", true, false) as Camera3D
	if cam != null:
		print("[probe] shot: worker at %s -> screen %s | customer at %s -> screen %s" % [
			str(worker.global_position), str(cam.unproject_position(worker.global_position + Vector3(0.0, 0.5, 0.0))),
			str(customer.global_position), str(cam.unproject_position(customer.global_position + Vector3(0.0, 0.6, 0.0)))])
	if img != null:
		print("[probe] shot: %s err=%d" % [GHOST_SHOT, img.save_png(GHOST_SHOT)])


## The intro, held on its second card, with the skip hint in the corner.
func _stage_intro_shot() -> void:
	var sub := _new_viewport()
	var scene := _new_main_scene(sub)
	await _frames(3)
	var ui := scene.get_node_or_null("UI")
	var intro: IntroSequence = ui.get_node_or_null("Intro") if ui != null else null
	_expect(intro != null, "shot: the main scene has the intro")
	if intro == null:
		return
	if ui.has_method("start_game"):
		ui.call("start_game", false)
	else:
		intro.play()
	var guard := 0.0
	while guard < 25.0 and int(intro.card_index) < 1:
		await _wait(0.05)
		guard += 0.05
	await _wait(0.5)  # let the card fade in
	var label := intro.skip_hint_label()
	_expect(label != null and label.is_visible_in_tree(), "shot: the hint is up in the intro")
	_expect(intro.running, "shot: the intro is running")
	await RenderingServer.frame_post_draw
	var img := sub.get_texture().get_image()
	_expect(img != null, "shot: the intro frame rendered")
	if img != null:
		if label != null:
			print("[probe] shot: the hint sits at %s in a %dx%d frame" % [
				str(_rect_of(label)), img.get_width(), img.get_height()])
		print("[probe] shot: %s err=%d" % [INTRO_SHOT, img.save_png(INTRO_SHOT)])


# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

## A bare kitchen built from a hand-made layout, no visuals (the probe is logic).
func _make_kitchen(layout: KitchenLayout) -> Kitchen:
	var kitchen := Kitchen.new()
	kitchen.name = "ProbeKitchen"
	kitchen.layout = layout
	kitchen.build_floor = false
	kitchen.build_walls = false
	kitchen.build_columns = false
	kitchen.show_grid = false
	add_child(kitchen)  # _ready -> rebuild()
	return kitchen


## A service over a probe kitchen. sim_speed stays 0: the probe ticks by hand.
func _make_service(kitchen: Kitchen) -> Service:
	var service := Service.new()
	service.name = "ProbeService"
	service.kitchen = kitchen
	service.sim_speed = 0.0
	add_child(service)
	_eaten = 0
	service.worker_consumed.connect(_on_worker_consumed)
	return service


## A customer that starts hunting at once (no climb-in pause) at [param cell].
func _spawn_customer(service: Service, cell: Vector2i) -> Customer:
	service.customer_enter_ticks = 0
	var customer := Customer.new()
	service.add_child(customer)
	customer.setup(service, cell)
	service.customers.append(customer)
	return customer


func _cleanup(service: Service, kitchen: Kitchen) -> void:
	service.queue_free()
	kitchen.queue_free()


func _on_worker_consumed(_worker: Worker) -> void:
	_eaten += 1


func _straight_line(count: int) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	for x in count:
		path.append(Vector2i(x, 0))
	return path


func _new_viewport() -> SubViewport:
	var sub := SubViewport.new()
	sub.size = Vector2i(1280, 720)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sub)
	return sub


func _new_main_scene(sub: SubViewport) -> Node:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	sub.add_child(scene)
	return scene


func _frames(count: int) -> void:
	for i in count:
		await get_tree().process_frame


func _wait(seconds: float) -> void:
	await get_tree().create_timer(maxf(seconds, 0.0)).timeout


func _rect_of(control: Control) -> Rect2i:
	var rect := control.get_global_rect()
	return Rect2i(roundi(rect.position.x), roundi(rect.position.y),
		roundi(rect.size.x), roundi(rect.size.y))


## The brightest pixel inside [param rect] (0..1); -1 when the rect is off-image.
func _brightest(img: Image, rect: Rect2i) -> float:
	var x0 := maxi(rect.position.x, 0)
	var y0 := maxi(rect.position.y, 0)
	var x1 := mini(rect.end.x, img.get_width())
	var y1 := mini(rect.end.y, img.get_height())
	if x1 <= x0 or y1 <= y0:
		return -1.0
	var best := 0.0
	for y in range(y0, y1):
		for x in range(x0, x1):
			best = maxf(best, img.get_pixel(x, y).get_luminance())
	return best


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("[probe] ok   ", label)
	else:
		_fails += 1
		print("[probe] FAIL ", label)
