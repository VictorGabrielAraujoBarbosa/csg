extends Node
## Dev helper: loads the main scene, waits a few frames, saves a screenshot and
## quits. Run with:
##   godot --path . res://tools/capture.tscn
## (Used by the agent to check the visuals without a human at the keyboard.)

const OUT_PATH := "/tmp/opencode/kitchen.png"

## Horror bookkeeping for the self-test (lambdas cannot capture locals by
## reference, so the counters live on the node).
var _horror_eaten := 0
## "A job lost its inputs" is a theft, not noise: a served day must not have one.
var _lost_inputs_seen := 0


func _count_lost_inputs(text: String) -> void:
	if text.contains("lost its inputs"):
		_lost_inputs_seen += 1


func _ready() -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(1280, 720)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sub)
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	sub.add_child(scene)
	var kitchen := scene.find_child("Kitchen", true, false) as Kitchen
	# The game ships with the authored start map; the capture always runs on the
	# demo kitchen so the tests and screenshots stay comparable.
	#   --layout=res://resources/layouts/start_kitchen.txt  to shoot another map
	var layout_override := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--layout="):
			layout_override = arg.split("=")[1]
	if kitchen != null:
		kitchen.layout = null
		kitchen.layout_file = layout_override if not layout_override.is_empty() \
			else "res://resources/layouts/demo_kitchen.txt"
	var rig := scene.find_child("CameraRig", true, false) as CameraRig
	# Optional view overrides, e.g.:
	#   godot --path . res://tools/capture.tscn -- --pitch=88 --dist=26
	for arg in OS.get_cmdline_user_args():
		if rig == null:
			break
		if arg.begins_with("--pitch="):
			rig.pitch_deg = float(arg.split("=")[1])
		elif arg.begins_with("--yaw="):
			rig.start_yaw_deg = float(arg.split("=")[1])
			rig._yaw_deg = rig.start_yaw_deg
		elif arg.begins_with("--dist="):
			rig.distance = float(arg.split("=")[1])
			rig._target_distance = rig.distance
			rig._distance = rig.distance
		elif arg.begins_with("--focus="):
			var parts := arg.split("=")[1].split(",")
			if parts.size() == 2:
				rig.focus_on(Vector3(float(parts[0]), 0.0, float(parts[1])))
	if rig != null:
		rig._apply()
	var look := scene.find_child("WorldEnvironment", true, false) as LookConfig
	if look != null:
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--ambient="):
				look.ambient_energy = float(arg.split("=")[1])
			elif arg.begins_with("--ssao-intensity="):
				look.ssao_intensity = float(arg.split("=")[1])
			elif arg.begins_with("--ssao-radius="):
				look.ssao_radius = float(arg.split("=")[1])
			elif arg.begins_with("--exposure="):
				look.tonemap_exposure = float(arg.split("=")[1])
			elif arg.begins_with("--contrast="):
				look.contrast = float(arg.split("=")[1])
			elif arg.begins_with("--saturation="):
				look.saturation = float(arg.split("=")[1])
		print("look: ambient=", look.ambient_energy, " ssao=", look.ssao_enabled,
			" intensity=", look.ssao_intensity, " radius=", look.ssao_radius,
			" exposure=", look.tonemap_exposure,
			" | env ssao=", look.environment.ssao_enabled if look.environment != null else "no env",
			" intensity=", look.environment.ssao_intensity if look.environment != null else -1)
	var sun := scene.find_child("Sun", true, false) as DirectionalLight3D
	if sun != null:
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--sun="):
				sun.light_energy = float(arg.split("=")[1])
		print("sun energy=", sun.light_energy, " shadows=", sun.shadow_enabled)
	var placer := scene.find_child("PlaceController", true, false) as PlaceController
	if placer != null:
		placer.set_process(false)
		placer.set_process_unhandled_input(false)
		for child in placer.get_children():
			if child is Node3D:
				(child as Node3D).visible = false
	if "--selftest" in OS.get_cmdline_user_args() and kitchen != null:
		await _self_test(kitchen, scene)
	if "--arc" in OS.get_cmdline_user_args():
		_run_arc(scene)
	if "--furniture" in OS.get_cmdline_user_args() and kitchen != null:
		_place_demo_furniture(kitchen)
	if "--sim" in OS.get_cmdline_user_args():
		_run_sim(scene)
	if "--sim-day" in OS.get_cmdline_user_args():
		_run_day(scene)
	if "--start-day" in OS.get_cmdline_user_args():
		_start_day(scene)
	if "--designer" in OS.get_cmdline_user_args():
		# Opens the level designer (the map editor + its authoring panel).
		var editor := scene.find_child("MapPaintController", true, false) as MapPaintController
		if editor != null:
			editor.set_active(true)
		var panel := scene.find_child("LevelDesigner", true, false) as Control
		print("[designer] panel=", panel, " children=", panel.get_child_count() if panel != null else -1)
		if panel != null:
			panel.set_designer_visible(true)
			print("[designer] visible=", panel.visible, " panel_node=", panel.get_node_or_null("DesignerPanel"))
	if "--horror" in OS.get_cmdline_user_args() or "--horror=" in " ".join(OS.get_cmdline_user_args()):
		if "--no-cutscene" in OS.get_cmdline_user_args():
			var ui := scene.get_node_or_null("UI")
			if ui != null:
				ui.cutscene = null
		_run_horror(scene)
	if "--sim-ticks=" in " ".join(OS.get_cmdline_user_args()) and kitchen != null:
		_run_sim_ticks(scene)
	if "--check" in OS.get_cmdline_user_args() and kitchen != null and kitchen.data != null:
		var text: String = kitchen.data.to_text()
		var reparsed := KitchenLayout.from_text(text)
		var same_floors: bool = reparsed.floors.size() == kitchen.data.floors.size()
		var floors_match := true
		for cell: Vector2i in kitchen.data.floors:
			if reparsed.get_floor(cell) != kitchen.data.get_floor(cell):
				floors_match = false
				print("[check] floor mismatch at ", cell, ": ", kitchen.data.get_floor(cell), " -> ", reparsed.get_floor(cell))
		var walls_match := true
		for key: Vector3i in kitchen.data.walls:
			if reparsed.get_wall_key(key) != kitchen.data.get_wall_key(key):
				walls_match = false
				print("[check] wall mismatch at ", key, ": ", kitchen.data.get_wall_key(key), " -> ", reparsed.get_wall_key(key))
		var tints_match := true
		for key: Vector3i in kitchen.data.wall_tints:
			if not _color_close(reparsed.wall_tints.get(key, Color.WHITE), kitchen.data.wall_tints[key]):
				tints_match = false
		for cell: Vector2i in kitchen.data.floor_tints:
			if not _color_close(reparsed.floor_tints.get(cell, Color.WHITE), kitchen.data.floor_tints[cell]):
				tints_match = false
		var points_match: bool = reparsed.points.size() == kitchen.data.points.size()
		for cell: Vector2i in kitchen.data.points:
			if reparsed.points.get(cell, -1) != kitchen.data.points[cell]:
				points_match = false
		var furniture_match: bool = reparsed.furniture.size() == kitchen.data.furniture.size()
		if furniture_match:
			for i in range(kitchen.data.furniture.size()):
				var a: Dictionary = kitchen.data.furniture[i]
				var b: Dictionary = reparsed.furniture[i]
				if a.id != b.id or a.cell != b.cell or a.steps != b.steps:
					furniture_match = false
					break
				var ta: Dictionary = a.get("tints", {})
				var tb: Dictionary = b.get("tints", {})
				if ta.size() != tb.size():
					furniture_match = false
					break
				for name: String in ta:
					if not _color_close(tb.get(name, Color.WHITE), ta[name]):
						furniture_match = false
		print("round-trip: floors ", kitchen.data.floors.size(), " -> ", reparsed.floors.size(),
			" match=", same_floors and floors_match,
			" | explicit walls ", kitchen.data.walls.size(), " -> ", reparsed.walls.size(),
			" match=", walls_match,
			" | wall/floor tints match=", tints_match,
			" | points ", kitchen.data.points.size(), " -> ", reparsed.points.size(),
			" match=", points_match,
			" | furniture ", kitchen.data.furniture.size(), " -> ", reparsed.furniture.size(),
			" match=", furniture_match)
	if "--pixeltest" in OS.get_cmdline_user_args() and kitchen != null:
		kitchen.paint_floor_tint(Vector2i(6, 3), Color(0.95, 0.35, 0.35))
	if "--paint-demo" in OS.get_cmdline_user_args() and kitchen != null:
		_paint_demo(kitchen)
	if "--item-showcase" in OS.get_cmdline_user_args():
		_item_showcase(scene)
	print("kitchen: ", kitchen, " data=", kitchen.data if kitchen != null else null,
		" floors=", kitchen.data.floors.size() if kitchen != null and kitchen.data != null else -1)
	if rig != null:
		var cam: Camera3D = rig.get_node_or_null("Camera3D")
		print("cam pos=", cam.global_position if cam != null else "none", " current=", cam.current if cam != null else false)
	for i in 45:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := sub.get_texture().get_image()
	if "--pixeltest" in OS.get_cmdline_user_args() and kitchen != null and rig != null:
		_pixel_test(image, kitchen, rig)
	var err := image.save_png(OUT_PATH)
	print("screenshot %s (err=%d)" % [OUT_PATH, err])
	get_tree().quit()


## Samples rendered pixels to catch things that "exist" but are invisible
## (e.g. a checker tint hidden by overexposure).
func _pixel_test(image: Image, kitchen: Kitchen, rig: CameraRig) -> void:
	var cam := rig.get_node_or_null("Camera3D") as Camera3D
	if cam == null:
		return
	var a := _sample_cell(image, cam, kitchen, Vector2i(2, 6))
	var b := _sample_cell(image, cam, kitchen, Vector2i(2, 7))
	var delta := absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
	_expect(delta > 0.004, "checker: adjacent floor tiles differ (delta %.4f)" % delta)
	var tinted := _sample_cell(image, cam, kitchen, Vector2i(6, 3))
	_expect(tinted.r > tinted.g + 0.05 and tinted.r > tinted.b + 0.05,
		"floor tint: painted cell renders red (%.2f %.2f %.2f)" % [tinted.r, tinted.g, tinted.b])


func _sample_cell(image: Image, cam: Camera3D, kitchen: Kitchen, cell: Vector2i) -> Color:
	var world := kitchen.cell_to_world(cell) + Vector3(0, 0.02, 0)
	var screen := cam.unproject_position(world)
	var x := clampi(int(screen.x), 0, image.get_width() - 1)
	var y := clampi(int(screen.y), 0, image.get_height() - 1)
	return image.get_pixel(x, y)


func _place_demo_furniture(kitchen: Kitchen) -> void:
	var by_id := {}
	for def in FurnitureCatalog.all():
		by_id[def.id] = def
	# Cooking run along the north wall (windows above the stove and sink).
	_put(kitchen, by_id, &"counter", Vector2i(2, 1), 0)
	_put(kitchen, by_id, &"stove", Vector2i(3, 1), 0)
	_put(kitchen, by_id, &"sink", Vector2i(4, 1), 0)
	_put(kitchen, by_id, &"counter", Vector2i(5, 1), 0)
	_put(kitchen, by_id, &"fridge", Vector2i(6, 1), 0)
	# Serving bar against the low-wall pass.
	_put(kitchen, by_id, &"bar", Vector2i(9, 7), 0)
	_put(kitchen, by_id, &"bar", Vector2i(10, 7), 0)
	_put(kitchen, by_id, &"bar_end", Vector2i(11, 7), 0)
	# Dining corner in the front area.
	_put(kitchen, by_id, &"table", Vector2i(9, 9), 0)
	_put(kitchen, by_id, &"chair", Vector2i(10, 10), 0)
	_put(kitchen, by_id, &"sofa_long", Vector2i(8, 8), 0)
	_put(kitchen, by_id, &"table_round", Vector2i(12, 9), 0)
	_put(kitchen, by_id, &"sofa", Vector2i(12, 1), 0)
	_put(kitchen, by_id, &"assembly_table", Vector2i(9, 4), 0)
	# Storage nook.
	_put(kitchen, by_id, &"shelf", Vector2i(1, 9), 0)
	_put(kitchen, by_id, &"trash", Vector2i(1, 10), 0)
	_put(kitchen, by_id, &"plant", Vector2i(3, 10), 0)


func _put(kitchen: Kitchen, by_id: Dictionary, id: StringName, cell: Vector2i, steps: int) -> void:
	if kitchen.furniture_at(cell) != null:
		return  # already furnished by the layout file
	var inst := kitchen.place_furniture(by_id[id], cell, steps)
	if inst == null:
		print("could not place ", id, " at ", cell)


## The demo arc, headless: days 1-3 must be winnable with the purchases the demo
## teaches (storage before day 1, a fryer before day 2) and the squeeze must end
## in a loss within a handful of days.
func _run_arc(scene: Node) -> void:
	var service := scene.find_child("Service", true, false) as Service
	var day := scene.find_child("DayController", true, false) as DayController
	var kitchen := scene.find_child("Kitchen", true, false) as Kitchen
	if service == null or day == null or kitchen == null:
		print("[arc] missing service / day / kitchen")
		return
	_reset_world(service)
	service.sim_speed = 0.0
	day.day = 0
	# The player's shopping list: storage first, then the fryer for day 2.
	kitchen.place_furniture(FurnitureCatalog.find(&"shelf"), Vector2i(1, 2), 0)
	kitchen.place_furniture(FurnitureCatalog.find(&"fridge"), Vector2i(7, 3), 0)
	service.rebuild_stations()
	var won: Array[int] = []
	var lost_on := 0
	for i in 8:
		if day.day == 1:
			# day 1's earnings buy the fryer, plus a third chibi for the rush
			kitchen.place_furniture(FurnitureCatalog.find(&"fryer"), Vector2i(7, 2), 0)
			kitchen.place_furniture(FurnitureCatalog.find(&"worker_post"), Vector2i(1, 4), 0)
			service.rebuild_stations()
		var reasons := day.can_start_day()
		if not reasons.is_empty():
			print("[arc] day %d blocked: %s" % [day.day + 1, reasons[0]])
			break
		day.start_day()
		var ticks := 0
		while day.phase == DayController.Phase.DAY and ticks < 6000:
			service.tick_once()
			ticks += 1
		if day.lost:
			lost_on = day.day
		else:
			won.append(day.day)
		print("[arc] day %d: %s, served %d/%d in %d ticks" % [
			day.day, "LOST" if day.lost else "won", day.served, day.plan.arrivals.size(), ticks])
		day.finish_day()
		if lost_on > 0:
			break
	day.day = 0  # leave the counter where the other tools expect it
	_reset_world(service)
	_expect(won.has(1) and won.has(2) and won.has(3), "arc: days 1, 2 and 3 are winnable (won: %s)" % str(won))
	_expect(lost_on >= 4 and lost_on <= 8, "arc: the squeeze ends in a loss by day 8 (lost on day %d)" % lost_on)


## Runs a whole day headlessly: gate -> start -> ticks until the summary, then
## the loss path (too many pending orders).
func _run_day(scene: Node) -> void:
	var service := scene.find_child("Service", true, false) as Service
	var day := scene.find_child("DayController", true, false) as DayController
	var kitchen := scene.find_child("Kitchen", true, false) as Kitchen
	if service == null or day == null:
		print("[day-sim] missing service or day controller")
		return
	service.worker_consumed.connect(func(_w: Worker) -> void: _horror_eaten += 1)
	service.warning.connect(_count_lost_inputs)
	_lost_inputs_seen = 0
	service.sim_speed = 0.0
	service.orders.arrive_on_turn_in = false
	day.day = 0
	_reset_world(service)
	# Start from a clean slate: leftover orders from earlier sims would otherwise
	# trip the "waited too long" loss rule immediately.
	var reasons := day.can_start_day()
	print("[day-sim] gate reasons: ", reasons)
	_expect(reasons.is_empty(), "day: the demo kitchen passes the gate")
	_expect(day.start_day(), "day: start accepted")
	var money_before: int = service.orders.money
	var ticks := 0
	while day.phase == DayController.Phase.DAY and ticks < 30000:
		service.tick_once()
		ticks += 1
	print("[day-sim] day %d finished in %d ticks: served=%d money=%d lost=%s reason=%s" % [
		day.day, ticks, day.served, service.orders.money, str(day.lost), day.loss_reason])
	for arrival: Dictionary in day.plan.arrivals:
		print("[day-sim]   arrival at %d: %s adds=%s removes=%s" % [
			int(arrival["tick"]), arrival["dish"], arrival["adds"], arrival["removes"]])
	for order in service.orders.orders:
		if order.is_active():
			print("[day-sim]   order #%d arrived at %d, age %d" % [
				order.id, order.created_tick, service.tick - order.created_tick])
	for line in service.events.slice(maxi(0, service.events.size() - 12)):
		print("    ", line)
	_expect(day.phase == DayController.Phase.SUMMARY, "day: reaches the summary")
	_expect(not day.lost, "day: completed without a loss")
	_expect(day.served == day.plan.arrivals.size(), "day: every scheduled order was served")
	_expect(service.orders.money == money_before + day.served * service.orders.reward_per_order,
		"day: every served order paid out")
	day.finish_day()
	_expect(day.phase == DayController.Phase.BUILD, "day: back to the build phase")
	_expect(_lost_inputs_seen == 0,
		"day: no job lost its inputs while serving (got %d)" % _lost_inputs_seen)
	# loss path: too many pending orders -> the customers break in and eat the staff
	_horror_eaten = 0
	_expect(day.start_day(), "day: a second day starts")
	for i in service.orders.max_pending + 2:
		service.request_order()
	service.tick_once()
	_expect(day.phase == DayController.Phase.DAY and day.lost and day.horror,
		"horror: too many pending orders loses the day and the mob comes in")
	var broken_before := kitchen.broken_edges().size()
	_expect(broken_before > 0, "horror: a window was smashed open (%d edges)" % broken_before)
	_expect(service.customers.size() > 0, "horror: customers climbed in through the window")
	var horror_ticks := 0
	while day.phase == DayController.Phase.DAY and horror_ticks < 2000:
		service.tick_once()
		horror_ticks += 1
	_expect(day.phase == DayController.Phase.SUMMARY and day.lost, "horror: the day ends after the attack")
	_expect(_horror_eaten == 3, "horror: every worker was eaten (got %d in %d ticks)" % [_horror_eaten, horror_ticks])
	_expect(service.workers.is_empty(), "horror: no staff left standing")
	_expect(service.customers.is_empty(), "horror: the customers are cleaned up")
	_expect(kitchen.broken_edges().size() == broken_before, "horror: broken windows stay broken for the day")
	_expect(kitchen.can_cross(Vector2i(3, 0), Vector2i(3, 1)), "horror: a broken window can be walked through")
	service._sync_workers()
	_expect(service.workers.is_empty(), "horror: an eaten post stays empty for the rest of the day")
	day.finish_day()
	_expect(service.workers.size() == 3, "horror: the staff is back for the next build phase")
	_expect(kitchen.broken_edges().is_empty(), "horror: the windows are repaired for the next day")
	_expect(not kitchen.can_cross(Vector2i(3, 0), Vector2i(3, 1)), "horror: the repaired window blocks again")
	# The day ends clean: nothing left over from the rush, trays back in the pool.
	service.reset_after_day()
	var leftover := 0
	for item in service.items.items:
		if item.def.id == &"tray":
			leftover += 1
	_expect(service.items.items.size() == leftover, "day end: only trays are left in the world")
	_expect(leftover == service.starting_trays,
		"day end: the tray pool is back to %d (got %d)" % [service.starting_trays, leftover])
	# The attack is deterministic: the same setup eats the same staff through the
	# same windows (the exact tick count depends on where the staff stood).
	_expect(day.start_day(), "horror: replay day starts")
	_horror_eaten = 0
	for i in service.orders.max_pending + 2:
		service.request_order()
	service.tick_once()
	var replay_ticks := 0
	while day.phase == DayController.Phase.DAY and replay_ticks < 2000:
		service.tick_once()
		replay_ticks += 1
	_expect(_horror_eaten == 3, "horror: the replay eats the same staff (got %d)" % _horror_eaten)
	_expect(kitchen.broken_edges().size() >= 2,
		"horror: the replay breaks windows again (%d edges)" % kitchen.broken_edges().size())
	day.finish_day()


## Loses the day on purpose and steps a few ticks into the attack, so a
## screenshot can catch the customers inside (see --horror=ticks).
func _run_horror(scene: Node) -> void:
	var service := scene.find_child("Service", true, false) as Service
	var day := scene.find_child("DayController", true, false) as DayController
	if service == null or day == null:
		return
	_reset_world(service)
	service.sim_speed = 0.0
	if not day.start_day():
		print("[horror] the day could not start")
		return
	for i in service.orders.max_pending + 2:
		service.request_order()
	service.tick_once()
	var ticks := 40
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--horror="):
			ticks = int(arg.split("=")[1])
	service.run_ticks(ticks)
	print("[horror] %d customers inside, %d workers left, %d broken edges, %d eaten" % [
		service.customers.size(), service.workers.size(),
		service.kitchen.broken_edges().size(), service.eaten_count()])


## Starts day 1 from a clean kitchen (for screenshots / real-time watching).
func _start_day(scene: Node) -> void:
	var service := scene.find_child("Service", true, false) as Service
	var day := scene.find_child("DayController", true, false) as DayController
	if service == null or day == null:
		return
	_reset_world(service)
	var reasons := day.can_start_day()
	print("[start-day] gate: ", reasons)
	if reasons.is_empty():
		day.start_day()


## Runs exactly N ticks (so a screenshot can catch workers mid-action).
func _run_sim_ticks(scene: Node) -> void:
	var service := scene.find_child("Service", true, false) as Service
	if service == null:
		return
	service.sim_speed = 0.0
	service.orders.arrive_on_turn_in = false
	if service.orders.active_orders().is_empty():
		service.request_order()
	for order in service.orders.active_orders():
		if order.state == Order.State.UNPLANNABLE:
			service.plan_order(order)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sim-ticks="):
			service.run_ticks(int(arg.split("=")[1]))
	for worker in service.workers:
		print("[sim-ticks] %s cell=%s state=%s carrying=%s" % [worker.name, worker.cell, worker.state_name(),
			worker.carried() != null])
	print("[sim-ticks] ", service.status_text())


## Puts the kitchen back into a reproducible starting state for the sims: no
## jobs, no active orders, no loose items and a full tray pool at the intake.
func _reset_world(service: Service) -> void:
	service.orders.arrive_on_turn_in = false
	for worker in service.workers:
		worker.force_idle()
	for job in service.board.jobs:
		service.board.cancel(job, "reset")
	service.board.cleanup()
	service.orders.orders.clear()
	service.orders.completed_count = 0
	service._stalled_seen.clear()
	for item in service.items.items.duplicate():
		service.items.remove(item)
	service._seed_trays()


## Runs the order -> jobs -> items pipeline headlessly (workers, tick by tick)
## and asserts the whole burger cycle, including tray recycling through the sink.
func _run_sim(scene: Node) -> void:
	var service := scene.find_child("Service", true, false) as Service
	if service == null:
		print("[sim] no service node")
		return
	service.sim_speed = 0.0  # manual, deterministic stepping
	service.orders.arrive_on_turn_in = false
	_reset_world(service)
	if service.orders.active_orders().is_empty():
		service.request_order()
	var completed_before: int = service.orders.completed_count
	var money_before: int = service.orders.money
	var ticks := service.run_until_idle(20000)
	print("[sim] first order: ticks=", ticks, " completed=", service.orders.completed_count,
		" money=", service.orders.money, " trays=", _tray_count(service),
		" items=", service.items.items.size())
	_expect(service.orders.completed_count == completed_before + 1, "sim: one order completed end to end")
	_expect(service.orders.money == money_before + service.orders.reward_per_order, "sim: order paid out")
	_expect(_tray_count(service) == 3, "sim: all trays accounted for")
	_expect(_log_has(service, "Plate Dish"), "sim: a dish was plated onto a tray")
	_expect(_log_has(service, "Hand Over"), "sim: the tray was handed over")
	# Now let turn-ins spawn follow-up orders; the 4th needs a washed tray.
	service.orders.arrive_on_turn_in = true
	service.request_order()
	var target_completed: int = completed_before + 4
	var loop_ticks := 0
	while service.orders.completed_count < target_completed and loop_ticks < 40000:
		if service.board.pending_count() == 0 and not service.has_active_jobs():
			break
		service.tick_once()
		loop_ticks += 1
	print("[sim] loop: ticks=", loop_ticks, " completed=", service.orders.completed_count,
		" money=", service.orders.money, " trays=", _tray_count(service))
	if service.orders.completed_count < target_completed:
		_stuck_report(service)
	_expect(service.orders.completed_count >= target_completed, "sim: repeated orders keep completing")
	_expect(_log_has(service, "Wash Tray"), "sim: the sink washed a dirty tray back into the pool")
	_expect(_tray_count(service) == 3, "sim: the tray pool stays whole after recycling")
	# Stop the order flow and clear the board, then everyone should walk home.
	service.orders.arrive_on_turn_in = false
	for order in service.orders.active_orders():
		service.board.cancel_for_order(order)
	service.run_ticks(200)
	var all_home := true
	for worker in service.workers:
		if worker.cell != worker.spawn_cell:
			all_home = false
			print("[sim]   not home: cell=%s home=%s state=%s job=%s" % [worker.cell, worker.spawn_cell,
				worker.state_name(), worker.job != null])
	print("[sim] workers home: ", all_home, " (", service.status_text(), ")")
	_expect(all_home, "sim: idle workers return to their posts")
	for line in service.events.slice(maxi(0, service.events.size() - 10)):
		print("    ", line)


func _tray_count(service: Service) -> int:
	var total := 0
	for id in ItemCatalog.tray_ids():
		total += service.items.count(id)
	return total


## Dumps why nothing is happening: pending jobs, their blockers and where every
## item and worker is sitting.
func _stuck_report(service: Service) -> void:
	print("[sim] stuck report — items:")
	for item in service.items.items:
		print("    ", item.describe(), " @ ", item.cell, " reserved=", item.reserved_by != null)
	print("[sim] stuck report — jobs:")
	for job in service.board.jobs:
		if job.state == Job.State.DONE:
			continue
		if job.state == Job.State.ACTIVE:
			print("    #%d %s [ACTIVE until tick %d]" % [job.id, job.describe(), job.finish_tick])
			continue
		if job.state == Job.State.FAILED:
			print("    #%d %s [FAILED: %s]" % [job.id, job.describe(), job.fail_reason])
			continue
		var blocker := ""
		if job.kind == Job.Kind.PRODUCE:
			var inputs: Variant = service.gather_inputs(job)
			blocker = "inputs ready" if inputs != null else "waiting for inputs"
			if job.station == null:
				blocker = "no station"
			elif job.station.busy_by != null and job.station.busy_by != job:
				blocker = "station busy"
			elif inputs == null:
				for entry in job.recipe.inputs:
					var need_id := StringName(entry.get("item", &""))
					var req := RecipeDef.payload_requirement(entry)
					print("      needs %s x%d match=%s" % [need_id, int(entry.get("amount", 1)), req])
					for cell in job.station.input_cells:
						for it in service.items.items_at(cell):
							print("        at %s: %s payload=%s reserved=%s" % [cell, it.def.id, it.payload, it.reserved_by != null])
		else:
			blocker = "item gone" if (job.item == null or not service.items.items.has(job.item)) else "ready"
		print("    #%d %s [%s]" % [job.id, job.describe(), blocker])
	print("[sim] stuck report — orders:")
	for order in service.orders.orders:
		if order.is_active():
			print("    #%d %s state=%d" % [order.id, order.dish_name, order.state])
	print("[sim] stuck report — workers:")
	for worker in service.workers:
		print("    %s cell=%s state=%s job=%s" % [worker.name, worker.cell, worker.state_name(),
			worker.job.describe() if worker.job != null else "-"])


func _log_has(service: Service, text: String) -> bool:
	for line in service.events:
		if line.contains(text):
			return true
	return false


## Spawns one of every item in a row and prints its measured size + height, so
## item scale, centering and surface heights can be eyeballed in one shot.
func _item_showcase(scene: Node) -> void:
	var service := scene.find_child("Service", true, false) as Service
	var kitchen := scene.find_child("Kitchen", true, false) as Kitchen
	if service == null or kitchen == null:
		return
	print("[showcase] surface heights: floor=%.2f fridge=%.2f counter=%.2f stove=%.2f point=%.2f"
		% [kitchen.surface_height(Vector2i(7, 6)), kitchen.surface_height(Vector2i(6, 1)),
			kitchen.surface_height(Vector2i(5, 1)), kitchen.surface_height(Vector2i(3, 1)),
			kitchen.surface_height(Vector2i(2, 3))])
	var cell := Vector2i(2, 6)
	for id in ItemCatalog.all().keys():
		var def := ItemCatalog.find(id)
		var item := service.items.spawn(def, cell, {}, 0.05)
		var aabb := MeshBounds.combined_aabb(item)
		print("[showcase] %-26s cell=%s size=(%.2f, %.2f, %.2f)" % [def.id, cell, aabb.size.x, aabb.size.y, aabb.size.z])
		cell.x += 1
	# And one item on each kind of surface, to check they sit on top.
	for cell_check in [Vector2i(3, 1), Vector2i(5, 1), Vector2i(6, 1), Vector2i(2, 3)]:
		var h := kitchen.surface_height(cell_check)
		service.items.spawn(ItemCatalog.find(&"burger"), cell_check, {}, h)
		print("[showcase] burger on %s sits at y=%.2f" % [cell_check, h])


## Paints a few things to eyeball the editing API: fills the void notch with a
## plating room, adds windows and a low wall, and tints some furniture + floor.
func _paint_demo(kitchen: Kitchen) -> void:
	for x in range(5, 8):
		for z in range(8, 11):
			kitchen.paint_floor(Vector2i(x, z), KitchenLayout.Floor.PLATING)
	for x in [5, 6]:
		kitchen.paint_wall(Vector2i(x, 10), KitchenLayout.DIR_Z, KitchenLayout.Wall.WINDOW)
	for z in [9, 10]:
		kitchen.paint_wall(Vector2i(7, z), KitchenLayout.DIR_X, KitchenLayout.Wall.LOW)
	for cell in [Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 3)]:
		kitchen.paint_floor_tint(cell, Color(0.85, 0.55, 0.6))
	var fridge := kitchen.furniture_at(Vector2i(6, 1))
	if fridge != null:
		kitchen.tint_furniture(fridge, Color(0.55, 0.8, 0.85))
	var table := kitchen.furniture_at(Vector2i(9, 9))
	if table != null:
		kitchen.tint_furniture(table, Color(0.95, 0.75, 0.45), "wood")
	var shelf := kitchen.furniture_at(Vector2i(1, 9))
	if shelf != null:
		kitchen.tint_furniture(shelf, Color(0.75, 0.6, 0.85))
	# per-material: colour the stove's cabinet doors only
	var stove := kitchen.furniture_at(Vector2i(3, 1))
	if stove != null:
		kitchen.tint_furniture(stove, Color(0.5, 0.85, 0.95), "wood")
	# wall tint along the new room
	kitchen.paint_wall_tint(Vector2i(5, 8), KitchenLayout.DIR_X, Color(0.85, 0.5, 0.55))
	kitchen.paint_wall_tint(Vector2i(6, 8), KitchenLayout.DIR_X, Color(0.85, 0.5, 0.55))


func _self_test(kitchen: Kitchen, scene: Node) -> void:
	var by_id := {}
	for def in FurnitureCatalog.all():
		by_id[def.id] = def
	var stove: FurnitureDef = by_id[&"stove"]
	var table: FurnitureDef = by_id[&"table"]
	var data: KitchenLayout = kitchen.data
	# --- multi-cell footprints ---
	_expect(by_id[&"sofa_long"].resolved_footprint() == Vector2i(3, 1), "auto footprint: long sofa is 3x1")
	var cross: Vector2i = by_id[&"table_cross"].resolved_footprint()
	print("[selftest] info - banquet table measures ", cross)
	_expect(cross.x >= 2 and cross.y >= 1, "auto footprint: banquet table is multi-cell")
	_expect(by_id[&"table_round"].resolved_footprint() == Vector2i(2, 2), "auto footprint: round table is 2x2")
	_expect(by_id[&"chair"].resolved_footprint() == Vector2i(1, 1), "auto footprint: chair is 1x1")
	_expect(table.cells(Vector2i(5, 5), 1)[1] == Vector2i(5, 4), "multi-cell rotation swaps axes")
	# --- placement rules ---
	_expect(kitchen.can_place(stove, Vector2i(8, 5), 0), "stove fits on a free floor cell")
	_expect(kitchen.place_furniture(stove, Vector2i(8, 5), 0) != null, "stove placed")
	_expect(not kitchen.can_place(stove, Vector2i(8, 5), 0), "occupied cell rejected")
	_expect(not kitchen.can_place(stove, Vector2i(0, 0), 0), "void cell rejected")
	_expect(not kitchen.can_place(stove, Vector2i(3, 0), 0), "cell outside the map rejected")
	_expect(not kitchen.can_place(table, Vector2i(4, 8), 0), "table cannot hang into the void")
	_expect(not kitchen.can_place(table, Vector2i(10, 8), 1), "wall blocks a straddling table")
	_expect(kitchen.remove_furniture_at(Vector2i(8, 5)), "stove removed")
	_expect(kitchen.can_place(stove, Vector2i(8, 5), 0), "cell free again")
	# --- map painting ---
	var furniture_before: int = data.furniture.size()
	_expect(kitchen.paint_floor(Vector2i(0, 0), KitchenLayout.Floor.TILE), "paint a floor cell in the void")
	_expect(kitchen.can_place(stove, Vector2i(0, 0), 0), "furniture fits on freshly painted floor")
	var inst := kitchen.place_furniture(stove, Vector2i(0, 0), 0, {"*": Color(0.95, 0.4, 0.4)})
	_expect(inst != null and inst.tint_for("*").is_equal_approx(Color(0.95, 0.4, 0.4)), "place tinted furniture")
	_expect(data.furniture.size() == furniture_before + 1, "furniture recorded in the layout data")
	_expect(not kitchen.paint_floor(Vector2i(0, 0), KitchenLayout.Floor.VOID), "cannot erase floor under furniture")
	_expect(kitchen.tint_furniture(inst, Color(0.4, 0.7, 0.95)), "tint placed furniture")
	var entry: Dictionary = data.furniture[furniture_before]
	_expect((entry.tints["*"] as Color).is_equal_approx(Color(0.4, 0.7, 0.95)), "tint synced to layout data")
	# per-material tinting
	_expect(kitchen.tint_furniture(inst, Color(0.9, 0.3, 0.2), "wood"), "tint one material group")
	_expect(inst.tint_for("wood").is_equal_approx(Color(0.9, 0.3, 0.2)), "material tint wins for that material")
	_expect(inst.tint_for("metal").is_equal_approx(Color(0.4, 0.7, 0.95)), "whole-piece tint covers the rest")
	entry = data.furniture[furniture_before]
	_expect((entry.tints["wood"] as Color).is_equal_approx(Color(0.9, 0.3, 0.2)), "material tint synced to layout data")
	_expect(kitchen.undo(), "undo removes the material tint")
	_expect(inst.tint_for("wood").is_equal_approx(Color(0.4, 0.7, 0.95)), "material tint undone")
	_expect(kitchen.remove_furniture_at(Vector2i(0, 0)), "furniture removed")
	_expect(data.furniture.size() == furniture_before, "removal synced to layout data")
	_expect(kitchen.paint_floor(Vector2i(0, 0), KitchenLayout.Floor.VOID), "erase the painted floor")
	# --- walls and furniture interactions ---
	_expect(kitchen.place_furniture(table, Vector2i(12, 9), 0) != null, "long table placed")
	_expect(not kitchen.paint_wall(Vector2i(12, 9), KitchenLayout.DIR_X, KitchenLayout.Wall.SOLID), "cannot paint a wall through a piece")
	kitchen.remove_furniture_at(Vector2i(12, 9))
	# --- dragging a placed piece (build-phase rearranging) ---
	_expect(kitchen.place_furniture(table, Vector2i(12, 9), 0) != null, "table placed for the drag test")
	var dragging := kitchen.furniture_at(Vector2i(12, 9))
	var entries_before := data.furniture.size()
	kitchen.begin_grab(dragging)
	_expect(kitchen.furniture_at(Vector2i(12, 9)) == null, "a grabbed piece leaves the occupancy map")
	_expect(kitchen.can_place(table, Vector2i(12, 9), 0), "its old cell is free while carried")
	_expect(not kitchen.move_furniture(dragging, Vector2i(60, 60), 0), "dragging onto void is refused")
	_expect(kitchen.furniture_at(Vector2i(12, 9)) == null, "a refused drag leaves the piece in hand")
	var drop_cell := Vector2i(12, 9)
	for candidate in [Vector2i(12, 7), Vector2i(10, 9), Vector2i(14, 9), Vector2i(12, 11)]:
		if kitchen.can_place(table, candidate, 0):
			drop_cell = candidate
			break
	_expect(drop_cell != Vector2i(12, 9), "found a free cell to drop onto")
	_expect(kitchen.move_furniture(dragging, drop_cell, 0), "drag moves the piece")
	_expect(kitchen.furniture_at(drop_cell) == dragging, "the piece occupies its new cell")
	_expect(data.furniture.size() == entries_before, "the move rewrites the layout entry")
	_expect(not kitchen.can_place(table, drop_cell, 0), "the new cell is taken afterwards")
	_expect(kitchen.undo() and kitchen.furniture_at(Vector2i(12, 9)) == dragging, "undo moves the piece back")
	kitchen.begin_grab(dragging)
	kitchen.cancel_grab(dragging)
	_expect(kitchen.furniture_at(Vector2i(12, 9)) == dragging, "cancelling a drag returns the piece home")
	kitchen.remove_furniture_at(Vector2i(12, 9))
	# --- picking a piece up with nothing selected (after a placement) ---
	var placer_pick := scene.find_child("PlaceController", true, false) as PlaceController
	if placer_pick != null:
		placer_pick.has_selection = false
		placer_pick._has_hover = true
		placer_pick._hover_cell = Vector2i(3, 1)
		placer_pick._valid = true  # stale validity is the trap
		placer_pick._try_place()
		_expect(placer_pick._grabbed != null, "build: a piece is pickable with nothing selected")
		placer_pick._cancel_grab()
		placer_pick._has_hover = false
	# --- work tiles exist for a plain station, not only for zoned ones ---
	var work_svc := scene.find_child("Service", true, false) as Service
	var stove_station: StationInstance = null
	if work_svc != null:
		for station: StationInstance in work_svc.stations:
			if station.def != null and station.def.id == &"stove":
				stove_station = station
				break
	_expect(stove_station != null and not stove_station.work_tiles.is_empty(),
		"work tiles: a plain 1x1 station knows where a worker can stand")
	# --- 2 m windows and doorways (painted as pairs, rendered with the native piece) ---
	var win_a := KitchenLayout.edge_key(Vector2i(3, 0), KitchenLayout.DIR_Z)
	var win_b := KitchenLayout.edge_key(Vector2i(4, 0), KitchenLayout.DIR_Z)
	_expect(data.get_wall_key(win_a) == KitchenLayout.Wall.WINDOW, "the demo map ships a window at (3,0)")
	var wall_keys := {}
	for key: Vector3i in data.walls:
		wall_keys[key] = true
	_expect(kitchen._find_partner(win_a, KitchenLayout.Wall.WINDOW, Color.WHITE, wall_keys, {}) == win_b,
		"the wall builder pairs collinear window edges into one native 2 m piece")
	var door_a := KitchenLayout.edge_key(Vector2i(13, 3), KitchenLayout.DIR_X)
	var door_b := KitchenLayout.edge_key(Vector2i(13, 4), KitchenLayout.DIR_X)
	_expect(kitchen._find_partner(door_a, KitchenLayout.Wall.DOORWAY, Color.WHITE, wall_keys, {}) == door_b,
		"and collinear doorway edges pair the same way")
	_expect(kitchen.wall_feature_partner(Vector3i(5, 5, KitchenLayout.DIR_X)) == Kitchen.NO_EDGE,
		"an open edge in the middle of the room has nothing to pair with")
	var free_edge := KitchenLayout.edge_key(Vector2i(6, 0), KitchenLayout.DIR_Z)
	_expect(data.get_wall_key(free_edge) == KitchenLayout.Wall.SOLID, "the probe edge is a plain wall")
	var free_partner := kitchen.wall_feature_partner(free_edge)
	_expect(free_partner == KitchenLayout.edge_key(Vector2i(7, 0), KitchenLayout.DIR_Z), "it pairs with the next cell along")
	_expect(kitchen.paint_wall_feature(free_edge, KitchenLayout.Wall.WINDOW), "painting a window paints the whole pair")
	_expect(data.get_wall_key(free_edge) == KitchenLayout.Wall.WINDOW
		and data.get_wall_key(free_partner) == KitchenLayout.Wall.WINDOW, "both edges became windows")
	_expect(not kitchen.paint_wall_feature(free_edge, KitchenLayout.Wall.DOORWAY), "an existing window is not painted over")
	_expect(kitchen.undo(), "undo the window feature")
	_expect(data.get_wall_key(free_edge) == KitchenLayout.Wall.SOLID
		and data.get_wall_key(free_partner) == KitchenLayout.Wall.SOLID, "undo restores both edges")
	_expect(kitchen.paint_wall_feature(free_edge, KitchenLayout.Wall.WINDOW), "paint the window again")
	_expect(kitchen.erase_wall_feature(free_edge), "erasing a window erases its pair")
	_expect(data.get_wall_key(free_edge) == KitchenLayout.Wall.OPEN
		and data.get_wall_key(free_partner) == KitchenLayout.Wall.OPEN, "both edges are gone")
	_expect(kitchen.undo(), "undo the erase")
	_expect(data.get_wall_key(free_edge) == KitchenLayout.Wall.WINDOW, "the window is back")
	_expect(kitchen.undo(), "undo the second paint")
	_expect(data.get_wall_key(free_edge) == KitchenLayout.Wall.SOLID, "the probe edge is a plain wall again")
	# The rendered piece for a paired feature is the native 2 m model (no squeeze).
	var window_piece := kitchen._spawn_piece("window", Vector3.ZERO, 0.0, 1.0, Vector3.ONE)
	_expect(window_piece != null, "the native window piece loads")
	if window_piece != null:
		window_piece.free()
	# --- work tiles: the tiles a worker can operate a piece from ---
	kitchen.set_work_markers([Vector2i(2, 2), Vector2i(3, 2)], true)
	_expect(kitchen._work_root != null and kitchen._work_root.visible
		and kitchen._work_root.get_child_count() >= 2, "work tiles: markers show for the given cells")
	kitchen.set_work_markers([], false)
	_expect(not kitchen._work_root.visible, "work tiles: they clear again")
	# --- level designer I/O: blank maps, save, load ---
	var blank := KitchenLayout.blank(Vector2i(6, 5))
	_expect(blank.floors.size() == 30, "designer: a blank map is all floor (30 cells)")
	_expect(blank.get_wall_key(KitchenLayout.edge_key(Vector2i(0, -1), KitchenLayout.DIR_Z)) == KitchenLayout.Wall.SOLID,
		"designer: blank maps derive their outer walls")
	_expect(blank.get_wall_key(KitchenLayout.edge_key(Vector2i(2, 2), KitchenLayout.DIR_Z)) == KitchenLayout.Wall.OPEN,
		"designer: and the inside of a blank map is open")
	var designer_floors := data.floors.size()
	var designer_walls := data.walls.size()
	var designer_furniture := data.furniture.size()
	var save_path := "user://maps/_designer_test.txt"
	_expect(kitchen.save_layout(save_path), "designer: the current map saves to disk")
	_expect(kitchen.load_layout("res://resources/layouts/start_kitchen.txt"), "designer: the start map loads")
	_expect(kitchen.data.points.size() == 2, "designer: the start map ships intake and delivery points")
	var start_ids: Array[StringName] = []
	for start_entry in kitchen.data.furniture:
		start_ids.append(start_entry.get("id", &""))
	_expect(start_ids.has(&"stove") and start_ids.has(&"worker_post") and start_ids.has(&"counter")
		and start_ids.has(&"sink") and start_ids.has(&"assembly_table"),
		"designer: the start map ships a cooking line and staff")
	_expect(not start_ids.has(&"shelf") and not start_ids.has(&"fridge"),
		"designer: day 1 has no storage — the player has to buy it")
	_expect(kitchen.load_layout(save_path), "designer: the saved map loads back")
	_expect(kitchen.data.floors.size() == designer_floors and kitchen.data.walls.size() == designer_walls
		and kitchen.data.furniture.size() == designer_furniture, "designer: the reloaded map matches")
	_expect(kitchen.load_layout("res://resources/layouts/demo_kitchen.txt"), "designer: back to the demo kitchen")
	data = kitchen.data  # loading replaced the layout object the tests hold on to
	_expect(kitchen.furniture_at(Vector2i(3, 1)) != null, "designer: the demo furniture is back")
	_expect(kitchen.paint_wall(Vector2i(12, 9), KitchenLayout.DIR_X, KitchenLayout.Wall.SOLID), "paint an interior wall")
	_expect(kitchen.paint_wall_tint(Vector2i(12, 9), KitchenLayout.DIR_X, Color(0.9, 0.6, 0.3)), "paint a wall tint")
	_expect((kitchen.data.wall_tints.get(KitchenLayout.edge_key(Vector2i(12, 9), KitchenLayout.DIR_X), Color.WHITE) as Color)
		.is_equal_approx(Color(0.9, 0.6, 0.3)), "wall tint stored in layout data")
	_expect(kitchen.undo(), "undo removes the wall tint")
	_expect(not kitchen.data.wall_tints.has(KitchenLayout.edge_key(Vector2i(12, 9), KitchenLayout.DIR_X)), "wall tint undone")
	_expect(kitchen.paint_wall(Vector2i(12, 9), KitchenLayout.DIR_X, KitchenLayout.Wall.OPEN), "erase the interior wall")
	# --- undo ---
	_expect(kitchen.paint_floor_tint(Vector2i(5, 5), Color(0.9, 0.5, 0.5)), "paint a floor tint")
	var tinted := kitchen.paint_floor(Vector2i(0, 0), KitchenLayout.Floor.PLATING)
	_expect(tinted and data.has_floor(Vector2i(0, 0)), "paint plating")
	_expect(kitchen.undo() and not data.has_floor(Vector2i(0, 0)), "undo removes the painted floor")
	_expect(kitchen.undo() and not data.floor_tints.has(Vector2i(5, 5)), "undo removes the floor tint")
	# --- UI: the kitchen frame forwards mouse input into the world viewport ---
	var ui := scene.get_node_or_null("UI")
	if ui != null:
		var world_vp := scene.find_child("World", true, false) as SubViewport
		var placer2 := scene.find_child("PlaceController", true, false) as PlaceController
		var frame := ui.get_node_or_null("KitchenFrame") as Control
		_expect(world_vp != null and frame != null, "ui: the kitchen frame shows the world viewport")
		if world_vp != null and frame != null and placer2 != null:
			var ev := InputEventMouseMotion.new()
			ev.position = frame.size * 0.5
			ev.global_position = ev.position
			ui._on_frame_input(ev)
			await get_tree().process_frame
			var world_mouse := world_vp.get_mouse_position()
			_expect(world_mouse.distance_to(frame.size * 0.5) < 4.0,
				"ui: forwarded input sets the world viewport mouse position (%s)" % world_mouse)
			# The capture disables the placer for clean screenshots; drive it once.
			placer2._process(0.016)
			_expect(placer2._has_hover, "ui: the placement controller picks up the forwarded mouse")
			placer2._hide()
			# Keyboard events must reach the controllers inside the SubViewport:
			# rotate, Esc and the map editor's tool keys depend on it.
			placer2.set_process_unhandled_input(true)
			placer2.has_selection = true
			var before_rot := placer2.rot_steps
			var key := InputEventKey.new()
			key.physical_keycode = KEY_R
			key.pressed = true
			ui._input(key)
			_expect(placer2.rot_steps != before_rot,
				"ui: R reaches the placement controller through the viewport")
			placer2.has_selection = false
			placer2.set_process_unhandled_input(false)
	# --- map paint controller ---
	var painter := scene.find_child("MapPaintController", true, false) as MapPaintController
	if painter != null:
		_expect(painter._edge_from_hit(Vector3(7.4, 0, 5.1), Vector2i(7, 5))
			== KitchenLayout.edge_key(Vector2i(7, 5), KitchenLayout.DIR_X), "hover near +x picks the east edge")
		_expect(painter._edge_from_hit(Vector3(6.6, 0, 5.1), Vector2i(7, 5))
			== KitchenLayout.edge_key(Vector2i(6, 5), KitchenLayout.DIR_X), "hover near -x picks the west edge")
		_expect(painter._edge_from_hit(Vector3(7.1, 0, 5.4), Vector2i(7, 5))
			== KitchenLayout.edge_key(Vector2i(7, 5), KitchenLayout.DIR_Z), "hover near +z picks the south edge")
		painter.set_active(true)
		painter._cell = Vector2i(7, 5)
		painter._edge = KitchenLayout.edge_key(Vector2i(7, 5), KitchenLayout.DIR_X)
		painter._has_hover = true
		painter.set_tool(MapPaintController.Tool.WALL)
		painter._apply_tool(false)
		_expect(kitchen.data.get_wall_key(painter._edge) == KitchenLayout.Wall.SOLID, "wall tool paints a wall")
		painter._erase_at_hover()
		_expect(kitchen.data.get_wall_key(painter._edge) == KitchenLayout.Wall.OPEN, "erase removes the wall again")
		painter._last_cell = Vector2i(1 << 30, 1 << 30)
		painter.set_tool(MapPaintController.Tool.TINT)
		painter.tint_index = 1
		painter._apply_tool(false)
		_expect(kitchen.data.floor_tints.has(Vector2i(7, 5)), "tint tool paints the floor")
		painter.set_tool(MapPaintController.Tool.ERASE)
		painter._erase_at_hover()
		_expect(not kitchen.data.floor_tints.has(Vector2i(7, 5)) and not kitchen.data.has_floor(Vector2i(7, 5)),
			"erase removes the floor tile and its tint")
		kitchen.paint_floor(Vector2i(7, 5), KitchenLayout.Floor.TILE)
		# tag presets
		var preset_stove := kitchen.place_furniture(by_id[&"stove"], Vector2i(6, 5), 0)
		_expect(preset_stove != null, "station placed for preset test")
		_expect(painter.preset_color(by_id[&"stove"]).is_equal_approx(Color(0.93, 0.55, 0.5)),
			"preset colour comes from the cooking tag")
		kitchen.tint_furniture(preset_stove, painter.preset_color(by_id[&"stove"]), "*")
		_expect(preset_stove.tint_for("*").is_equal_approx(Color(0.93, 0.55, 0.5)), "preset applied to the piece")
		kitchen.remove_furniture_at(Vector2i(6, 5))
		painter.set_active(false)
	# --- items, recipes and stations ---
	_expect(ItemCatalog.find(&"tray") != null and not ItemCatalog.find(&"tray").is_base,
		"the tray is a finite (non-base) item")
	_expect(ItemCatalog.find(&"bread").is_base and ItemCatalog.find(&"bread").source_tag == &"storage",
		"bread is a base ingredient taken from storage")
	var burger_recipe := RecipeCatalog.find(&"burger")
	_expect(burger_recipe != null and burger_recipe.inputs.size() == 4, "the burger recipe has four inputs")
	_expect(RecipeCatalog.find(&"make_salad").output_amount == 2, "the salad recipe yields two")
	_expect(RecipeCatalog.find(&"slice_cheese").output_amount == 6, "the cheese recipe yields six slices")
	_expect(RecipeCatalog.source_for(&"tomato") != null and RecipeCatalog.source_for(&"tomato").is_source,
		"base ingredients get a take-from-storage recipe")
	# station zones rotate with the piece
	var rot_inst := kitchen.place_furniture(by_id[&"assembly_table"], Vector2i(5, 5), 1)
	_expect(rot_inst != null, "assembly table placed rotated")
	if rot_inst != null:
		var station := StationInstance.from_furniture(rot_inst)
		_expect(station.input_cells.size() == 1 and station.input_cells[0] == Vector2i(5, 5),
			"rotated assembly input zone")
		_expect(station.work_cells.size() == 1 and station.work_cells[0] == Vector2i(5, 4),
			"rotated assembly work zone")
		_expect(station.output_cells.size() == 1 and station.output_cells[0] == Vector2i(5, 3),
			"rotated assembly output zone")
		kitchen.remove_furniture_at(Vector2i(5, 5))
	# the planner explains what is missing (pretend the kitchen is empty)
	var service := scene.find_child("Service", true, false) as Service
	if service != null:
		service.planner.items = service.items
		service.planner.stations = []  # nothing built: planning must refuse
		service.planner.board = service.board
		service.planner.warnings.clear()
		var probe := Order.new()
		probe.id = 999
		probe.recipe_id = &"burger"
		probe.dish_name = "Burger"
		var planned := service.planner.plan_order(probe, service.tick)
		_expect(not planned, "the planner refuses an order it cannot make")
		_expect(_contains(service.planner.warnings, "delivery") or _contains(service.planner.warnings, "assembly"),
			"the planner explains what is missing")
		service.planner.stations = service.stations
		# --- build-phase money ---
		var wallet: OrderManager = service.orders
		var purse: int = wallet.money
		_expect(wallet.try_spend(100), "money: spending works when affordable")
		_expect(wallet.money == purse - 100, "money: spending deducts the cost")
		wallet.add_money(100)
		_expect(wallet.money == purse, "money: refunds add back")
		_expect(not wallet.try_spend(purse + 10), "money: spending more than the purse is refused")
		_expect(wallet.money == purse, "money: a refused purchase changes nothing")
		# --- shop, decor and composed props ---
		var shop_ids: Array[StringName] = []
		for def in FurnitureCatalog.shop_items():
			shop_ids.append(def.id)
		for wanted in [&"stove", &"sink", &"counter", &"assembly_table", &"worker_post", &"shelf", &"fridge"]:
			_expect(shop_ids.has(wanted), "shop: %s is on sale" % wanted)
		_expect(not shop_ids.has(&"plant") and not shop_ids.has(&"sofa") and not shop_ids.has(&"trash")
			and not shop_ids.has(&"table_round"), "shop: decor and functionless pieces are not on sale")
		_expect(FurnitureCatalog.shop_categories().size() >= 3, "shop: the pieces are grouped into categories")
		var cutting := FurnitureCatalog.find(&"cutting_table")
		_expect(cutting != null and cutting.shop, "props: the composed cutting table is a shop item")
		if cutting != null:
			_expect(cutting.resolved_footprint() == Vector2i(1, 1), "props: the cutting table measures 1x1")
			_expect(is_equal_approx(cutting.surface_override, 0.9), "props: it declares its work surface height")
			var placed_prop := kitchen.place_furniture(cutting, Vector2i(2, 9), 0)
			_expect(placed_prop != null, "props: the cutting table can be placed")
			if placed_prop != null:
				_expect(is_equal_approx(kitchen.surface_height(Vector2i(2, 9)), 0.9),
					"props: items rest on its counter, not on the bowl")
				kitchen.remove_furniture_at(Vector2i(2, 9))
		var plating := FurnitureCatalog.find(&"plating_station")
		_expect(plating != null and plating.resolved_footprint() == Vector2i(1, 1),
			"props: the plating station measures 1x1 too")
		# --- modifiers: variants and payload matching ---
		var no_cheese := RecipeCatalog.variant_of(&"burger", [&"no_cheese"])
		_expect(no_cheese != null and no_cheese.variant_id == &"burger__no_cheese",
			"variant: a no-cheese burger gets a derived variant id")
		var has_cheese_input := false
		for variant_entry in no_cheese.inputs:
			if StringName(variant_entry.get("item", &"")) == &"cheese_slice":
				has_cheese_input = true
		_expect(not has_cheese_input, "variant: the no-cheese recipe drops the cheese input")
		_expect(RecipeCatalog.variant_of(&"burger", []).variant_id == &"",
			"variant: an unmodified dish has no variant id")
		var probe_dish := service.items.spawn(ItemCatalog.find(&"burger"), Vector2i(9, 5),
			{"variant": "burger__no_cheese"}, 0.05)
		_expect(not probe_dish.matches(&"burger", -1, {"variant": ""}),
			"variant: a modified dish does not satisfy a plain order")
		_expect(probe_dish.matches(&"burger", -1, {"variant": "burger__no_cheese"}),
			"variant: it does satisfy its own variant")
		service.items.remove(probe_dish)
		# Day 2's hook: fries are produced at a frying station, so a + fries
		# order cannot be served until the player buys a fryer.
		var fryer_def := FurnitureCatalog.find(&"fryer")
		_expect(fryer_def != null and fryer_def.has_tag(&"frying"), "fryer: the shop piece carries the frying tag")
		var without_fryer := service.can_serve(&"burger", [&"add_fries"], [])
		var wants_frying := false
		for text in without_fryer:
			if text.contains("frying"):
				wants_frying = true
		_expect(wants_frying, "fryer: without one the gate asks for a frying station")
		var fryer_cell := Vector2i(2, 2)
		_expect(kitchen.place_furniture(fryer_def, fryer_cell, 0) != null, "fryer: it can be placed")
		service.rebuild_stations()
		var mod_order := service.orders.spawn(&"burger", [&"add_fries"], [&"no_cheese"])
		_expect(service.plan_order(mod_order), "fryer: a + fries order plans once it exists")
		var fetches_cheese := false
		var makes_fries := false
		for job in service.board.jobs:
			if job.recipe == null:
				continue
			if job.recipe.is_source and job.recipe.output == &"cheese_slice":
				fetches_cheese = true
			if job.recipe.output == &"fries":
				makes_fries = true
		_expect(not fetches_cheese, "modifier order never fetches the removed ingredient")
		_expect(makes_fries, "modifier order produces the add-on (fries are not a shelf item any more)")
		service.board.cancel_for_order(mod_order)
		mod_order.state = Order.State.FAILED
		kitchen.remove_furniture_at(fryer_cell)
		service.rebuild_stations()
		# --- the Start Day gate ---
		_expect(service.can_serve(&"burger", [], []).is_empty(),
			"gate: the demo kitchen can serve a plain burger")
		_expect(not service.can_serve(&"burger", [&"add_fries"], [&"no_cheese"]).is_empty(),
			"gate: a + fries order is blocked without a frying station")
		var saved_stations := service.stations.duplicate()
		var no_cooking: Array[StationInstance] = []
		for st in service.stations:
			if not st.has_tag(&"cooking"):
				no_cooking.append(st)
		service.stations = no_cooking
		var reasons_bad := service.can_serve(&"burger", [], [])
		_expect(not reasons_bad.is_empty(), "gate: a kitchen without a stove is refused")
		_expect(_contains(reasons_bad, "cooking") or _contains(reasons_bad, "Cooked Patty"),
			"gate: the refusal names what is missing")
		service.stations = saved_stations
		# --- day plans are deterministic ---
		var plan_a := DayPlan.generate(1, 1234, [&"burger"], [&"add_fries", &"no_cheese"], 3, 600, 2)
		var plan_b := DayPlan.generate(1, 1234, [&"burger"], [&"add_fries", &"no_cheese"], 3, 600, 2)
		_expect(plan_a.arrivals.size() == 3, "day plan: day one asks three orders")
		var identical := plan_a.arrivals.size() == plan_b.arrivals.size()
		for i in plan_a.arrivals.size():
			if not identical:
				break
			var ra: Dictionary = plan_a.arrivals[i]
			var rb: Dictionary = plan_b.arrivals[i]
			if ra["tick"] != rb["tick"] or ra["dish"] != rb["dish"] \
					or ra["adds"] != rb["adds"] or ra["removes"] != rb["removes"]:
				identical = false
		_expect(identical, "day plan: the same seed replays the same day")
		var plan_c := DayPlan.generate(1, 4321, [&"burger"], [&"add_fries", &"no_cheese"], 3, 600, 2)
		var differs := false
		for i in mini(plan_a.arrivals.size(), plan_c.arrivals.size()):
			var ra2: Dictionary = plan_a.arrivals[i]
			var rc: Dictionary = plan_c.arrivals[i]
			if ra2["tick"] != rc["tick"] or ra2["adds"] != rc["adds"] or ra2["removes"] != rc["removes"]:
				differs = true
		_expect(differs, "day plan: a different seed makes a different day")
		var in_range := true
		for arrival: Dictionary in plan_a.arrivals:
			if int(arrival["tick"]) < 0 or int(arrival["tick"]) > plan_a.max_ticks:
				in_range = false
		_expect(in_range, "day plan: arrivals fit inside the day")
		# --- presentation: motion is time-based, not frame- or tick-based ---
		var item_a := service.items.spawn(ItemCatalog.find(&"burger"), Vector2i(9, 6), {}, 0.05)
		var target_a := WorldItem.cell_position(Vector2i(12, 6), 0.05)
		item_a.begin_move(target_a, 1.0)
		item_a._process(0.5)
		_expect(absf(item_a.visual_position().x - (9.0 + 1.5)) < 0.01,
			"presentation: half a duration is halfway")
		item_a._process(0.5)
		_expect(item_a.visual_position().is_equal_approx(target_a),
			"presentation: the move lands exactly on target")
		var item_b := service.items.spawn(ItemCatalog.find(&"burger"), Vector2i(9, 7), {}, 0.05)
		var target_b := WorldItem.cell_position(Vector2i(12, 7), 0.05)
		item_b.begin_move(target_b, 1.0)
		for i in 20:
			item_b._process(0.05)
		_expect(item_b.visual_position().is_equal_approx(target_b),
			"presentation: frame count does not change the result")
		service.items.remove(item_a)
		service.items.remove(item_b)
		# --- items occupy one slot each (no stacking) ---
		var slot_cell := Vector2i(7, 6)
		for i in 6:
			service.items.spawn(ItemCatalog.find(&"cheese_slice"), slot_cell, {}, 0.05)
		_expect(service.items.items_at(slot_cell).size() == 6, "six cheese slices are six separate items")
		var min_slot := 999.0
		for i in 6:
			for j in range(i + 1, 6):
				min_slot = minf(min_slot, ItemManager.slot_offset(i).distance_to(ItemManager.slot_offset(j)))
		_expect(min_slot > 0.2, "slots: items on one cell never share a spot (min %.2f m)" % min_slot)
		for item in service.items.items_at(slot_cell):
			service.items.remove(item)
		# --- pathfinding follows the kitchen rules ---
		_expect(not Pathfinder.find_path(kitchen, Vector2i(2, 2), Vector2i(4, 2)).is_empty(),
			"pathfinder: straight line across the main room")
		var detour := Pathfinder.find_path(kitchen, Vector2i(2, 2), Vector2i(12, 9))
		_expect(not detour.is_empty(), "pathfinder: reaches the front area")
		_expect(detour.size() > absi(12 - 2) + absi(9 - 2), "pathfinder: takes the detour around the notch (%d cells)" % detour.size())
		_expect(Pathfinder.find_path(kitchen, Vector2i(2, 2), Vector2i(6, 9)).is_empty(),
			"pathfinder: no path into the void")
		_expect(Pathfinder.find_path(kitchen, Vector2i(2, 2), Vector2i(0, 0)).is_empty(),
			"pathfinder: no path outside the map")
		_expect(service.workers.size() == _post_count(kitchen), "one worker per placed post (%d)" % _post_count(kitchen))
		# --- assignment picks the cheapest coupling ---
		var wa := Worker.new()
		wa.cell = Vector2i(0, 0)
		var wb := Worker.new()
		wb.cell = Vector2i(10, 0)
		var ja := Job.new()
		ja.location = Vector2i(1, 0)
		ja.created_at = 0
		var jb := Job.new()
		jb.location = Vector2i(9, 0)
		jb.created_at = 5
		var cost := func(w: Worker, j: Job) -> float:
			return float(absi(w.cell.x - j.location.x) + absi(w.cell.y - j.location.y))
		var pairs := JobAssignment.match([wa, wb], [ja, jb], cost)
		_expect(pairs.size() == 2, "assignment: both jobs get a worker")
		_expect(pairs[0]["worker"] == wa and pairs[0]["job"] == ja,
			"assignment: the older job takes the nearest worker")
		_expect(pairs[1]["worker"] == wb and pairs[1]["job"] == jb,
			"assignment: the other worker takes the other job")
		# the case that trips up per-worker greedy claiming: the older job is far
		# from the first worker but close to the second
		var wc := Worker.new()
		wc.cell = Vector2i(5, 0)
		var jc := Job.new()
		jc.location = Vector2i(10, 0)
		jc.created_at = 0
		var jd := Job.new()
		jd.location = Vector2i(0, 0)
		jd.created_at = 9
		var pairs2 := JobAssignment.match([wa, wc], [jc, jd], cost)
		_expect(pairs2.size() == 2 and pairs2[0]["worker"] == wc and pairs2[0]["job"] == jc,
			"assignment: the nearer worker is preferred even if listed later")
		_expect(pairs2[1]["worker"] == wa and pairs2[1]["job"] == jd,
			"assignment: the first worker takes what is left nearby")
		wa.free()
		wb.free()
		wc.free()
		# --- placing a post spawns a worker; removing it despawns ---
		var post_cell := Vector2i(7, 2)
		var before := service.workers.size()
		var placed := kitchen.place_furniture(FurnitureCatalog.find(&"worker_post"), post_cell, 0,
			{"*": Color(0.9, 0.4, 0.4)})
		_expect(placed != null, "worker post placed")
		_expect(service.workers.size() == before + 1, "placing a post spawns a worker")
		var new_worker := service._worker_at(post_cell)
		_expect(new_worker != null and new_worker.spawn_cell == post_cell, "the worker's home is the post")
		_expect(new_worker != null and new_worker.tint_color.is_equal_approx(Color(0.9, 0.4, 0.4)),
			"the worker inherits the post's colour")
		kitchen.remove_furniture_at(post_cell)
		_expect(service.workers.size() == before, "removing the post despawns the worker")
		_expect(Pathfinder.adjacent_walkable(kitchen, Vector2i(2, 3), Vector2i(2, 5)) != Vector2i(-2147483647, -2147483647),
			"the intake point has somewhere to stand")


func _contains(lines: Array, text: String) -> bool:
	for line in lines:
		if String(line).contains(text):
			return true
	return false


func _post_count(kitchen: Kitchen) -> int:
	var count := 0
	for inst in kitchen.get_furniture_instances():
		if inst.def.has_tag(&"worker"):
			count += 1
	return count


func _expect(condition: bool, label: String) -> void:
	print("[selftest] %s - %s" % ["ok" if condition else "FAIL", label])


## Colours round-trip through 8-bit hex, so compare with a small tolerance.
func _color_close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01
