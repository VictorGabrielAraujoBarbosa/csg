extends Node
## Dev helper: loads the main scene, waits a few frames, saves a screenshot and
## quits. Run with:
##   godot --path . res://tools/capture.tscn
## (Used by the agent to check the visuals without a human at the keyboard.)

const OUT_PATH := "/tmp/opencode/kitchen.png"


func _ready() -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(1280, 720)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sub)
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	sub.add_child(scene)
	var kitchen := scene.get_node_or_null("Kitchen") as Kitchen
	var rig := scene.get_node_or_null("CameraRig") as CameraRig
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
	var look := scene.get_node_or_null("WorldEnvironment") as LookConfig
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
	var sun := scene.get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--sun="):
				sun.light_energy = float(arg.split("=")[1])
		print("sun energy=", sun.light_energy, " shadows=", sun.shadow_enabled)
	var placer := scene.get_node_or_null("PlaceController") as PlaceController
	if placer != null:
		placer.set_process(false)
		placer.set_process_unhandled_input(false)
		for child in placer.get_children():
			if child is Node3D:
				(child as Node3D).visible = false
	if "--selftest" in OS.get_cmdline_user_args() and kitchen != null:
		_self_test(kitchen, scene)
	if "--furniture" in OS.get_cmdline_user_args() and kitchen != null:
		_place_demo_furniture(kitchen)
	if "--sim" in OS.get_cmdline_user_args():
		_run_sim(scene)
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
		kitchen.paint_floor_tint(Vector2i(4, 6), Color(0.95, 0.35, 0.35))
	if "--paint-demo" in OS.get_cmdline_user_args() and kitchen != null:
		_paint_demo(kitchen)
	if "--item-showcase" in OS.get_cmdline_user_args():
		_item_showcase(scene)
	print("kitchen: ", kitchen, " data=", kitchen.data if kitchen != null else null,
		" floors=", kitchen.data.floors.size() if kitchen != null and kitchen.data != null else -1)
	if rig != null:
		var cam: Camera3D = rig.get_node_or_null("Camera3D")
		print("cam pos=", cam.global_position if cam != null else "none", " current=", cam.current if cam != null else false)
	for i in 20:
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
	var tinted := _sample_cell(image, cam, kitchen, Vector2i(4, 6))
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


## Runs the order -> jobs -> items pipeline headlessly (instant executor) and
## asserts the whole burger cycle, including the tray recycling through the sink.
func _run_sim(scene: Node) -> void:
	var service := scene.get_node_or_null("Service") as Service
	if service == null:
		print("[sim] no service node")
		return
	service.sim_speed = 0.0  # manual, deterministic stepping
	service.orders.arrive_on_turn_in = false
	# The service tried to plan before the furniture existed; plan for real now.
	for order in service.orders.active_orders():
		service.plan_order(order)
	var ticks := service.run_until_idle(4000)
	print("[sim] first order: ticks=", ticks, " completed=", service.orders.completed_count,
		" money=", service.orders.money, " trays=", _tray_count(service),
		" items=", service.items.items.size())
	_expect(service.orders.completed_count == 1, "sim: one order completed end to end")
	_expect(service.orders.money == service.orders.reward_per_order, "sim: order paid out")
	_expect(_tray_count(service) == 3, "sim: all trays accounted for")
	_expect(_log_has(service, "Plate Dish"), "sim: a dish was plated onto a tray")
	_expect(_log_has(service, "Hand Over"), "sim: the tray was handed over")
	# Now let turn-ins spawn follow-up orders; the 4th needs a washed tray.
	service.orders.arrive_on_turn_in = true
	service.request_order()
	var loop_ticks := 0
	while service.orders.completed_count < 4 and loop_ticks < 8000:
		if service.board.pending_count() == 0 and not service.has_active_jobs():
			break
		service.tick_once()
		loop_ticks += 1
	print("[sim] loop: ticks=", loop_ticks, " completed=", service.orders.completed_count,
		" money=", service.orders.money, " trays=", _tray_count(service))
	if service.orders.completed_count < 4:
		_stuck_report(service)
	_expect(service.orders.completed_count >= 4, "sim: repeated orders keep completing")
	_expect(_log_has(service, "Wash Tray"), "sim: the sink washed a dirty tray back into the pool")
	_expect(_tray_count(service) == 3, "sim: the tray pool stays whole after recycling")
	for line in service.events.slice(maxi(0, service.events.size() - 10)):
		print("    ", line)


func _tray_count(service: Service) -> int:
	var total := 0
	for id in ItemCatalog.tray_ids():
		total += service.items.count(id)
	return total


## Dumps why the executor has nothing to do: pending jobs, their blockers and
## where every item is sitting.
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
			var inputs: Variant = service.executor._gather_inputs(job)
			blocker = "inputs ready" if inputs != null else "waiting for inputs"
			if job.station == null:
				blocker = "no station"
			elif job.station.busy_by != null and job.station.busy_by != job:
				blocker = "station busy"
		else:
			blocker = "item gone" if (job.item == null or not service.items.items.has(job.item)) else "ready"
		print("    #%d %s [%s]" % [job.id, job.describe(), blocker])
	print("[sim] stuck report — orders:")
	for order in service.orders.orders:
		if order.is_active():
			print("    #%d %s state=%d" % [order.id, order.dish_name, order.state])


func _log_has(service: Service, text: String) -> bool:
	for line in service.events:
		if line.contains(text):
			return true
	return false


## Spawns one of every item in a row and prints its measured size + height, so
## item scale, centering and surface heights can be eyeballed in one shot.
func _item_showcase(scene: Node) -> void:
	var service := scene.get_node_or_null("Service") as Service
	var kitchen := scene.get_node_or_null("Kitchen") as Kitchen
	if service == null or kitchen == null:
		return
	print("[showcase] surface heights: floor=%.2f fridge=%.2f counter=%.2f stove=%.2f point=%.2f"
		% [kitchen.surface_height(Vector2i(7, 6)), kitchen.surface_height(Vector2i(6, 1)),
			kitchen.surface_height(Vector2i(5, 1)), kitchen.surface_height(Vector2i(3, 1)),
			kitchen.surface_height(Vector2i(2, 3))])
	var cell := Vector2i(2, 6)
	for id in ItemCatalog.all().keys():
		var def := ItemCatalog.find(id)
		var item := service.items.spawn(def, cell, 1, {}, 0.05)
		var aabb := MeshBounds.combined_aabb(item)
		print("[showcase] %-26s cell=%s size=(%.2f, %.2f, %.2f)" % [def.id, cell, aabb.size.x, aabb.size.y, aabb.size.z])
		cell.x += 1
	# And one item on each kind of surface, to check they sit on top.
	for cell_check in [Vector2i(3, 1), Vector2i(5, 1), Vector2i(6, 1), Vector2i(2, 3)]:
		var h := kitchen.surface_height(cell_check)
		service.items.spawn(ItemCatalog.find(&"burger"), cell_check, 1, {}, h)
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
	# --- map paint controller ---
	var painter := scene.get_node_or_null("MapPaintController") as MapPaintController
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
	# the planner explains what is missing
	var service := scene.get_node_or_null("Service") as Service
	if service != null:
		service.planner.items = service.items
		service.planner.stations = service.stations
		service.planner.board = service.board
		service.planner.warnings.clear()
		var probe := Order.new()
		probe.id = 999
		probe.recipe_id = &"burger"
		probe.dish_name = "Burger"
		var planned := service.planner.plan_order(probe, service.tick)
		_expect(not planned, "the planner refuses an order it cannot make")
		_expect(_contains(service.planner.warnings, "assembly"),
			"the planner explains the missing station")
		# --- presentation: motion is time-based, not frame- or tick-based ---
		var item_a := service.items.spawn(ItemCatalog.find(&"burger"), Vector2i(9, 6), 1, {}, 0.05)
		var target_a := WorldItem.cell_position(Vector2i(12, 6), 0.05)
		item_a.begin_move(target_a, 1.0)
		item_a._process(0.5)
		_expect(absf(item_a.visual_position().x - (9.0 + 1.5)) < 0.01,
			"presentation: half a duration is halfway")
		item_a._process(0.5)
		_expect(item_a.visual_position().is_equal_approx(target_a),
			"presentation: the move lands exactly on target")
		var item_b := service.items.spawn(ItemCatalog.find(&"burger"), Vector2i(9, 7), 1, {}, 0.05)
		var target_b := WorldItem.cell_position(Vector2i(12, 7), 0.05)
		item_b.begin_move(target_b, 1.0)
		for i in 20:
			item_b._process(0.05)
		_expect(item_b.visual_position().is_equal_approx(target_b),
			"presentation: frame count does not change the result")
		service.items.remove(item_a)
		service.items.remove(item_b)


func _contains(lines: Array, text: String) -> bool:
	for line in lines:
		if String(line).contains(text):
			return true
	return false


func _expect(condition: bool, label: String) -> void:
	print("[selftest] %s - %s" % ["ok" if condition else "FAIL", label])


## Colours round-trip through 8-bit hex, so compare with a small tolerance.
func _color_close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01
