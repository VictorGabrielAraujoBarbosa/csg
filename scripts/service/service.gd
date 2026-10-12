class_name Service
extends Node3D
## Owns the simulated kitchen: items, stations, the job board, the planner, the
## workers and the orders.
##
## The simulation advances in fixed TICKS (see [member ticks_per_second]); every
## timed thing (recipes, walking, order limits) is counted in ticks, so a run is
## deterministic and can be replayed at any speed. Presentation is separate:
## item and worker views interpolate in real time, never per tick.

signal warning(text: String)
signal state_changed
## Emitted after every simulation tick; the day controller listens to this so
## arrivals and day-end checks are tick-driven and deterministic.
signal tick_passed(tick: int)

@export var kitchen: Kitchen

@export_group("Simulation")
## Fixed simulation rate. All durations in the game are ticks.
@export var ticks_per_second := 10
## 1 = real time, 0 = manual stepping (tests), higher = fast-forward.
@export var sim_speed := 1.0
## Safety valve so a slow frame cannot spiral into hundreds of ticks.
@export var max_ticks_per_frame := 5

@export_group("Workers")
## Scale of the toilet mesh.
@export var worker_scale := 2.0
## Default colour for workers whose post has no paint of its own.
@export var worker_tint := Color(0.82, 0.88, 0.98)
## Ticks a worker spends crossing one cell.
@export var walk_ticks_per_cell := 2

@export_group("Job picking")
@export var age_weight := 1.0
@export var distance_weight := 0.15

@export_group("Orders")
@export var starting_trays := 3

var items: ItemManager
var orders: OrderManager
var board := JobBoard.new()
var planner := Planner.new()
var stations: Array[StationInstance] = []
var workers: Array[Worker] = []

## Simulation clock, in ticks.
var tick := 0
var events: Array[String] = []

var _accumulator := 0.0
var _warning_seen: Dictionary = {}


func tick_seconds() -> float:
	return 1.0 / float(maxi(ticks_per_second, 1))


func _ready() -> void:
	if kitchen == null:
		kitchen = get_node_or_null("../Kitchen") as Kitchen
	items = ItemManager.new()
	items.name = "Items"
	add_child(items)
	orders = OrderManager.new()
	orders.name = "Orders"
	add_child(orders)
	orders.warning.connect(_on_warning)
	orders.order_added.connect(_on_order_added)
	if kitchen != null:
		kitchen.layout_rebuilt.connect(_on_layout_changed)
		kitchen.layout_edited.connect(_on_layout_changed)
	rebuild_stations()
	_seed_trays()
	_sync_workers()


func _process(delta: float) -> void:
	if sim_speed <= 0.0:
		return
	var step := tick_seconds()
	_accumulator += delta * sim_speed
	var budget := max_ticks_per_frame
	while _accumulator >= step and budget > 0:
		_accumulator -= step
		budget -= 1
		tick_once()


## One tick of the world: hand out jobs, workers act, stuck orders retry.
func tick_once() -> void:
	tick += 1
	orders.tick_once()
	_assign_jobs()
	for worker in workers:
		worker.tick(tick)
	if ticks_per_second > 0 and tick % maxi(ticks_per_second * 2, 1) == 0:
		_retry_unplannable()
	tick_passed.emit(tick)
	state_changed.emit()


## Test / cutscene helper: advance an exact number of ticks, ignoring real time.
func run_ticks(count: int) -> void:
	for i in count:
		tick_once()


## Advances ticks until no job is pending or running (or the cap is hit) and
## returns how many ticks that took. Deterministic.
func run_until_idle(max_ticks := 40000) -> int:
	var spent := 0
	while spent < max_ticks:
		if board.pending_count() == 0 and not has_active_jobs():
			break
		tick_once()
		spent += 1
	return spent


func has_active_jobs() -> bool:
	for job in board.jobs:
		if job.state == Job.State.ACTIVE:
			return true
	return false


func workers_busy() -> int:
	var busy := 0
	for worker in workers:
		if worker.state != Worker.State.IDLE:
			busy += 1
	return busy


func request_order(dish: StringName = &"burger", adds: Array = [], removes: Array = []) -> Order:
	return orders.spawn(dish, adds, removes)


## Every new order gets planned straight away; if that is impossible right now
## it becomes UNPLANNABLE and is retried when the kitchen changes.
func _on_order_added(order: Order) -> void:
	if order.state != Order.State.WAITING:
		return
	if not plan_order(order):
		order.state = Order.State.UNPLANNABLE
		emit_warning("Cannot plan order %d (%s) yet" % [order.id, order.dish_name])


func plan_order(order: Order) -> bool:
	planner.items = items
	planner.stations = stations
	planner.board = board
	planner.warnings.clear()
	var ok := planner.plan_order(order, tick)
	for text in planner.warnings:
		emit_warning(text)
	if ok:
		_log("planned order %d (%s)" % [order.id, order.dish_name])
	return ok


# ---------------------------------------------------------------------------
# Job execution (driven by workers)
# ---------------------------------------------------------------------------

## The coupling pass: ready jobs in priority order (oldest first), each taking
## the cheapest free worker. JobAssignment is the pure matcher; the cost
## function is where worker types will add their own terms.
func _assign_jobs() -> void:
	var free: Array[Worker] = []
	for worker in workers:
		if worker.job == null and (worker.state == Worker.State.IDLE or worker.state == Worker.State.TO_HOME):
			free.append(worker)
	if free.is_empty():
		return
	var ready: Array[Job] = []
	for job in board.jobs:
		if job.state == Job.State.PENDING and job_ready(job):
			ready.append(job)
	if ready.is_empty():
		return
	ready.sort_custom(func(a: Job, b: Job) -> bool: return a.created_at < b.created_at)
	var pairs := JobAssignment.match(free, ready, assignment_cost)
	for pair: Dictionary in pairs:
		_assign(pair["worker"], pair["job"])


## What it costs to send [param worker] after [param job]: distance for now,
## worker-type suitability later.
func assignment_cost(worker: Worker, job: Job) -> float:
	var distance := absi(worker.cell.x - job.location.x) + absi(worker.cell.y - job.location.y)
	return float(distance) * maxf(distance_weight, 0.0001)


func _assign(worker: Worker, job: Job) -> void:
	job.state = Job.State.ACTIVE
	job.started_tick = tick
	if job.kind == Job.Kind.PRODUCE and job.station != null:
		job.station.busy_by = job
	worker.accept(job)
	_log("worker takes #%d %s" % [job.id, job.describe()])


func job_ready(job: Job) -> bool:
	if job.kind == Job.Kind.TRANSFER:
		if job.item == null or not items.items.has(job.item):
			return false
		return job.item.reserved_by == null or job.item.reserved_by == job
	if job.station == null:
		return false
	if job.station.busy_by != null and job.station.busy_by != job:
		return false
	return gather_inputs(job) != null


## The items that satisfy a produce job's inputs, or null if they are not all
## sitting on the station's input cells yet. Every item is one unit, so
## "2 tomatoes" means two tomato items. Payload requirements (order / dish
## variant) are honoured.
func gather_inputs(job: Job) -> Variant:
	var order_id := job.order.id if job.order != null else -1
	var found: Array = []
	for entry in job.recipe.inputs:
		var item_id: StringName = entry.get("item", &"")
		var need := int(entry.get("amount", 1))
		var match_rule := RecipeDef.payload_requirement(entry)
		var collected: Array[WorldItem] = []
		for cell in job.station.input_cells:
			for item in items.items_at(cell):
				if item.reserved_by != null and item.reserved_by != job:
					continue
				if item.matches(item_id, order_id, match_rule):
					collected.append(item)
					if collected.size() >= need:
						break
			if collected.size() >= need:
				break
		if collected.size() < need:
			return null
		found.append({"items": collected, "amount": need, "payload_match": match_rule})
	return found


## A worker picks an item up: it leaves the world grid and rides in its hands.
func pick_up(job: Job, worker: Worker) -> WorldItem:
	var item := job.item
	if item == null or not items.items.has(item):
		return null
	items.detach_for_carry(item)
	item.attach_to(worker.hands(), Vector3(0.0, 0.06, 0.0))
	return item


## A carry finished: the item lands in its slot at the destination.
func finish_transfer(job: Job) -> void:
	var item := job.item
	if item == null or not items.items.has(item):
		job.state = Job.State.FAILED
		job.fail_reason = "item vanished"
		emit_warning("A carry job lost its item")
		if job.order != null:
			plan_order(job.order)
		return
	items.finish_carry(item, job.target_cell, kitchen.surface_height(job.target_cell))
	item.reserved_by = null
	job.state = Job.State.DONE
	_log("carried %s -> %s" % [item.def.id, job.target_cell])


## A produce job finished: consume the inputs, spawn the outputs, run effects.
func finish_produce(job: Job) -> void:
	if job.station != null:
		job.station.busy_by = null
	var inputs: Variant = gather_inputs(job)
	if inputs == null:
		job.state = Job.State.FAILED
		job.fail_reason = "inputs missing"
		emit_warning("A job lost its inputs (%s)" % job.recipe.display_name)
		if job.order != null:
			plan_order(job.order)
		return
	var entries: Array = inputs
	for entry in entries:
		for item: WorldItem in entry.items:
			items.consume(item)
	var out_def := ItemCatalog.find(job.recipe.output)
	var cell := job.station.output_cell()
	var out: WorldItem = null
	for i in maxi(job.recipe.output_amount, 1):
		out = items.spawn(out_def, cell, payload_for(job, entries), kitchen.surface_height(cell))
	job.state = Job.State.DONE
	_log("%s -> %s @ %s" % [job.recipe.display_name, job.recipe.output, cell])
	if job.recipe.effect == &"complete_order" and job.order != null:
		orders.complete(job.order)
	if job.deliver_to != Job.NO_CELL and out != null:
		var follow := Job.new()
		follow.kind = Job.Kind.TRANSFER
		follow.item = out
		follow.target_cell = job.deliver_to
		follow.order = job.order
		follow.parent = job
		follow.location = out.cell
		follow.created_at = tick
		out.reserved_by = follow
		board.add(follow)


## A worker gives up on a job (no path, item gone): warn, cancel, re-plan.
func fail_job(job: Job, reason: String) -> void:
	if job == null:
		return
	board.cancel(job, reason)
	emit_warning("Job %s failed: %s" % [job.step_label(), reason])
	if job.order != null:
		plan_order(job.order)


func drop_carried(item: WorldItem, cell: Vector2i) -> void:
	items.finish_carry(item, cell, kitchen.surface_height(cell))
	item.reserved_by = null


## Payload stamping.
##  - "order": the item is marked with its order (packed trays).
##  - "order_dish": the plated tray takes its order from the tray input, its
##    dish/variant from the dish input and records the add-ons.
##  - any recipe with [member RecipeDef.variant_id] stamps the variant, so only
##    a matching dish can satisfy a modified order.
func payload_for(job: Job, entries: Array) -> Dictionary:
	var payload := {}
	match String(job.recipe.stamp):
		"order":
			if job.order != null:
				payload["order"] = job.order.id
		"order_dish":
			for entry in entries:
				var req := RecipeDef.payload_requirement(entry)
				if req.has("order") and not (entry.items as Array).is_empty():
					payload = ((entry.items as Array)[0] as WorldItem).payload.duplicate()
			var dish_found := false
			var adds := PackedStringArray()
			for entry in entries:
				if (entry.items as Array).is_empty():
					continue
				var item := (entry.items as Array)[0] as WorldItem
				if item.def.id == &"tray_with_order":
					continue
				if not dish_found:
					dish_found = true
					payload["dish"] = item.def.id
					payload["variant"] = item.payload.get("variant", "")
				else:
					adds.append(String(item.def.id))
			payload["adds"] = adds
	if job.recipe.variant_id != &"":
		payload["variant"] = job.recipe.variant_id
	return payload


## Dry-run gate: can this kitchen serve the dish with these modifiers right now?
## Returns an empty array when it can, or the reasons why not.
func can_serve(dish: StringName, adds: Array = [], removes: Array = []) -> Array[String]:
	var probe := Order.new()
	probe.id = -1
	probe.recipe_id = dish
	for id: StringName in adds:
		probe.adds.append(id)
	for id: StringName in removes:
		probe.removes.append(id)
	var variant := RecipeCatalog.variant_of(dish, probe.removes)
	probe.variant = variant.variant_id if variant != null else &""
	planner.items = items
	planner.stations = stations
	planner.board = board
	planner.warnings.clear()
	planner.dry_run = true
	var ok := planner.plan_order(probe, tick)
	planner.dry_run = false
	if ok:
		return []
	return planner.warnings.duplicate()


# ---------------------------------------------------------------------------
# Stations, trays, workers
# ---------------------------------------------------------------------------

## Stations come from placed furniture (anything with capability tags) plus the
## structural intake / delivery points. Worker posts are not stations.
func rebuild_stations() -> void:
	stations.clear()
	if kitchen == null or kitchen.data == null:
		return
	for inst in kitchen.get_furniture_instances():
		if inst.def.tags.is_empty() or inst.def.has_tag(&"worker"):
			continue
		stations.append(StationInstance.from_furniture(inst))
	for cell: Vector2i in kitchen.data.points:
		stations.append(StationInstance.from_point(cell, kitchen.data.points[cell]))
	_log("stations: %d" % stations.size())


func _seed_trays() -> void:
	var intake := _station_with_tag(&"intake")
	if intake == null:
		emit_warning("No order intake point in the kitchen")
		return
	if starting_trays <= 0:
		return
	var tray_def := ItemCatalog.find(&"tray")
	for i in maxi(starting_trays, 0):
		items.spawn(tray_def, intake.input_cell(), {}, kitchen.surface_height(intake.input_cell()))
	_log("seeded %d trays at the intake" % starting_trays)


## Workers exist exactly for the placed worker posts: placing one spawns a
## chibi whose home is that cell; removing it despawns them.
func _sync_workers() -> void:
	if kitchen == null:
		return
	var posts: Dictionary = {}  # Vector2i -> FurnitureInstance
	for inst in kitchen.get_furniture_instances():
		if inst.def.has_tag(&"worker"):
			posts[inst.anchor] = inst
	for i in range(workers.size() - 1, -1, -1):
		var worker := workers[i]
		if posts.has(worker.spawn_cell):
			continue
		workers.remove_at(i)
		worker.despawn()
	for cell: Vector2i in posts:
		if _worker_at(cell) != null:
			continue
		var post: FurnitureInstance = posts[cell]
		var worker := Worker.new()
		add_child(worker)
		worker.setup(self, cell, post.tint_for("*"))
		workers.append(worker)
	_log("workers: %d" % workers.size())


func _worker_at(cell: Vector2i) -> Worker:
	for worker in workers:
		if worker.spawn_cell == cell:
			return worker
	return null


func _station_with_tag(tag: StringName) -> StationInstance:
	for station in stations:
		if station.has_tag(tag):
			return station
	return null


## Warnings are deduplicated so a stuck order does not spam the console.
func emit_warning(text: String) -> void:
	var last: int = _warning_seen.get(text, -99999)
	if tick - last < maxi(ticks_per_second * 6, 1):
		return
	_warning_seen[text] = tick
	warning.emit(text)


func _retry_unplannable() -> void:
	for order in orders.orders:
		if order.state == Order.State.UNPLANNABLE:
			if plan_order(order):
				order.state = Order.State.IN_PROGRESS


func _on_layout_changed() -> void:
	rebuild_stations()
	_sync_workers()


func _on_warning(text: String) -> void:
	emit_warning(text)


func _log(text: String) -> void:
	events.append("[t%5d] %s" % [tick, text])
	if events.size() > 400:
		events.pop_front()


func status_text() -> String:
	var active := orders.active_orders()
	return "tick %d | orders %d | money %d | jobs %d | items %d | workers %d/%d" % [
		tick, active.size(), orders.money, board.pending_count(), items.items.size(),
		workers_busy(), workers.size()
	]


func _exit_tree() -> void:
	# Static catalog caches hold imported scenes; release them so the engine
	# shuts down without "resources still in use" warnings.
	ItemCatalog.clear_caches()
	RecipeCatalog.clear_caches()
	FurnitureCatalog.clear_caches()
	if OS.get_cmdline_user_args().has("--dump-events"):
		_dump_state()


## Dev helper (run with `-- --dump-events`): prints the whole service state at
## shutdown so a stall in a real game run can be diagnosed.
func _dump_state() -> void:
	print("---- service dump: tick %d, money %d, completed %d ----" % [tick, orders.money, orders.completed_count])
	for line in events:
		print("  ev ", line)
	for order in orders.orders:
		print("  order #%d %s state=%d" % [order.id, order.dish_name, order.state])
	for worker in workers:
		print("  worker %s cell=%s state=%s job=%s" % [worker.name, worker.cell, worker.state_name(),
			worker.job.describe() if worker.job != null else "-"])
	for job in board.jobs:
		print("  job #%d %s state=%d %s" % [job.id, job.describe(), job.state, job.fail_reason])
	for item in items.items:
		print("  item %s @ %s reserved=%s" % [item.describe(), item.cell, item.reserved_by != null])
