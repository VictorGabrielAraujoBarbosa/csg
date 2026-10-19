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
## Presentation hooks: the VFX / audio layers listen to these, so every effect is
## driven by the simulation instead of guessing from the view. Purely cosmetic —
## nothing in the sim may depend on a listener.
## A worker starts operating a station (or picking an ingredient off a surface).
signal work_started(worker: Worker, job: Job)
## That work finished and its outputs were spawned.
signal work_finished(worker: Worker, job: Job)
## A finished order left the kitchen through [param cell].
signal order_delivered(order: Order, cell: Vector2i)
## A worker lifted an item into its hands.
signal item_carried(item: WorldItem, worker: Worker)
## A carried item landed on [param cell].
signal item_dropped(item: WorldItem, cell: Vector2i)
## A window / wall edge broke open (the horror event).
signal window_broken(edge: Vector3i)
## A worker was eaten by a customer (the horror event).
signal worker_consumed(worker: Worker)
## The mob came in / the attack is over (the cutscene listens to these).
signal mob_started(edges: Array)
signal mob_finished

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

@export_group("Horror")
## Scale of the customer mesh (a placeholder radioactive toilet).
@export var customer_scale := 2.0
## Ticks a customer spends crossing a cell — faster than a worker's walk.
@export var customer_ticks_per_cell := 1
## How long a customer takes to climb in before it starts hunting (ticks).
@export var customer_enter_ticks := 12
## Ticks a customer spends chewing after a meal.
@export var customer_chew_ticks := 6
## How often fleeing workers re-plan their escape.
@export var flee_replan_ticks := 8

var items: ItemManager
var orders: OrderManager
var board := JobBoard.new()
var planner := Planner.new()
var stations: Array[StationInstance] = []
var workers: Array[Worker] = []
## The horror: customers that broke in, and whether the attack is running.
var customers: Array[Customer] = []
var mob_active := false

## Simulation clock, in ticks.
var tick := 0
var events: Array[String] = []

var _accumulator := 0.0
var _warning_seen: Dictionary = {}
## Posts whose worker was eaten: nobody stands there until the next day.
var _eaten_posts: Dictionary = {}
## How many watchdog checks in a row an order has had no work (see _retry_stalled_orders).
var _stalled_seen: Dictionary = {}
## Re-plan orders that lost all their jobs (the day controller turns this on while
## a day is running; headless sims leave it off so they stay reproducible).
var watchdog_enabled := false


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
	orders.order_failed.connect(_on_order_failed)
	if kitchen != null:
		kitchen.layout_rebuilt.connect(_on_layout_changed)
		kitchen.layout_edited.connect(_on_layout_changed)
		# Undoing a sale in the build phase charges the refund back to this purse.
		kitchen.wallet = orders
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
	if mob_active:
		_tick_mob()
	else:
		_assign_jobs()
		for worker in workers:
			worker.tick(tick)
		if ticks_per_second > 0 and tick % maxi(ticks_per_second * 2, 1) == 0:
			_retry_unplannable()
			_sweep_stale_reservations()
			if watchdog_enabled:
				_retry_stalled_orders()
	tick_passed.emit(tick)
	state_changed.emit()


# ---------------------------------------------------------------------------
# The horror: customers break in and eat the staff
# ---------------------------------------------------------------------------

## Smashes the windows and lets the mob in. Returns the broken edges (empty when
## the kitchen has no window to break through).
func start_mob(count: int) -> Array[Vector3i]:
	var broken: Array[Vector3i] = []
	if kitchen == null or kitchen.data == null or count <= 0:
		return broken
	var windows := _window_edges()
	if windows.is_empty():
		return broken
	# Prefer windows far from the staff: the mob should have to come in and hunt.
	windows.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		var sa := _window_score(a)
		var sb := _window_score(b)
		if sa != sb:
			return sa > sb
		return a.x * 10000 + a.y * 10 + a.z < b.x * 10000 + b.y * 10 + b.z)
	# One window per customer, cycled when there are more customers than windows.
	var entry_edges: Array[Vector3i] = []
	for i in count:
		var edge: Vector3i = windows[i % windows.size()]
		if kitchen.is_broken(edge):
			continue
		var smashed := kitchen.break_wall_feature(edge)
		if smashed.is_empty():
			continue
		broken.append_array(smashed)
		entry_edges.append(edge)
		window_broken.emit(edge)
	if broken.is_empty():
		return broken
	for i in count:
		var edge: Vector3i = entry_edges[i % entry_edges.size()]
		var customer := Customer.new()
		add_child(customer)
		customer.setup(self, _inside_cell(edge))
		customers.append(customer)
	mob_active = true
	_log("mob: %d customers through %d window(s)" % [customers.size(), entry_edges.size()])
	mob_started.emit(broken)
	return broken


## Ends the attack (timeout / cleanup): the customers leave, the day can close.
func stop_mob() -> void:
	if not mob_active and customers.is_empty():
		return
	mob_active = false
	for customer in customers:
		customer.despawn()
	customers.clear()
	mob_finished.emit()


## Cells where a worker is operating right now. Others route around them; the
## pathfinder's fallback means this can never make a target unreachable.
func busy_worker_cells(except: Worker = null) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for worker in workers:
		if worker == except or worker.eaten:
			continue
		if worker.state == Worker.State.WORK:
			out.append(worker.cell)
	return out


func living_workers() -> Array[Worker]:
	var out: Array[Worker] = []
	for worker in workers:
		if not worker.eaten:
			out.append(worker)
	return out


## A customer reaches a worker: the worker is gone for the rest of the day.
func eat_worker(worker: Worker, customer: Customer) -> void:
	if worker == null or worker.eaten:
		return
	var where := worker.cell
	var home := worker.spawn_cell
	worker.eaten = true
	worker.despawn()
	workers.erase(worker)
	_eaten_posts[home] = true
	_log("customer eats a worker at %s" % where)
	worker_consumed.emit(worker)
	if living_workers().is_empty():
		mob_active = false
		for other in customers:
			other.despawn()
		customers.clear()
		mob_finished.emit()


## The staff is back on shift (a new day starts): eaten posts are staffed again.
func clear_eaten_posts() -> void:
	if _eaten_posts.is_empty():
		return
	_eaten_posts.clear()
	_sync_workers()


## An order died before it was delivered: give its ingredients back to the pool.
## Dishes simply lose their order tag and become free for anyone; trays get
## special treatment, because a tray is a physical thing that has to stay in the
## cycle: a packed tray is clean again, a plated tray becomes dirty (the food was
## made and never handed over, so it still needs washing).
func release_order_items(order: Order) -> void:
	if order == null:
		return
	board.cancel_for_order(order, "order failed")
	var released := 0
	for item in items.items.duplicate():
		if int(item.payload.get("order", -1)) != order.id:
			continue
		match item.def.id:
			&"tray_with_order":
				_swap_item(item, &"tray")
			&"tray_with_finished_order":
				_swap_item(item, &"tray_dirty")
			_:
				item.payload.erase("order")
		released += 1
	if released > 0:
		_log("order %d failed: %d item(s) released back into the kitchen" % [order.id, released])


## Replaces an item with another kind of item in the same slot (tray states).
func _swap_item(item: WorldItem, new_id: StringName) -> void:
	var def := ItemCatalog.find(new_id)
	if def == null:
		items.remove(item)
		return
	var cell := item.cell
	var height := item.base_height
	items.remove(item)
	items.spawn(def, cell, {}, height)


func _on_order_failed(order: Order, _reason: String) -> void:
	release_order_items(order)


## The staff that did not survive the day.
func eaten_count() -> int:
	return _eaten_posts.size()


func _tick_mob() -> void:
	if tick % maxi(flee_replan_ticks, 1) == 0:
		var threats: Array[Vector2i] = []
		for customer in customers:
			threats.append(customer.cell)
		for worker in living_workers():
			worker.flee_from(threats)
	# The workers have to tick too, or a fleeing worker plans a path nobody ever
	# walks: FLEE was a pose while the mob was in.
	for worker in living_workers():
		worker.tick(tick)
	for customer in customers:
		customer.tick(tick)


## Every window edge in the map, in a stable order.
func _window_edges() -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	for key: Vector3i in kitchen.data.walls:
		if int(kitchen.data.walls[key]) == KitchenLayout.Wall.WINDOW:
			out.append(key)
	out.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.x * 10000 + a.y * 10 + a.z < b.x * 10000 + b.y * 10 + b.z)
	return out


## How far a window is from the nearest living worker (higher = better entry).
func _window_score(edge: Vector3i) -> int:
	var inside := _inside_cell(edge)
	var best := 1 << 20
	for worker in living_workers():
		best = mini(best, absi(worker.cell.x - inside.x) + absi(worker.cell.y - inside.y))
	return best if best < (1 << 20) else 0


## The floor cell just inside a window edge (where the customer climbs in).
func _inside_cell(edge: Vector3i) -> Vector2i:
	var cells := KitchenLayout.edge_cells(edge)
	for c in cells:
		if kitchen.is_walkable(c):
			return c
	return cells[0]


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


## Clears the world between days: nobody carries anything, no job survives the
## day and every loose item is gone. The tray pool is seeded again exactly like
## at startup, so the next day begins with a clean kitchen.
## Safe when the kitchen has no intake point (it just warns, like [method _seed_trays]).
func reset_after_day() -> void:
	for worker in workers:
		worker.force_idle()
	for job in board.jobs.duplicate():
		board.cancel(job, "the day is over")
	var cleared := items.items.size()
	for item in items.items.duplicate():
		items.remove(item)
	_seed_trays()
	_log("day reset: %d items cleared, trays re-seeded" % cleared)


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
	item_carried.emit(item, worker)
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
	# The item was fetched FOR a consumer: it stays held for it, or another
	# order's job can take it off the station and the consumer starves.
	item.reserved_by = _landing_holder(job)
	job.state = Job.State.DONE
	_release_held_items(job)
	item_dropped.emit(item, job.target_cell)
	_log("carried %s -> %s" % [item.def.id, job.target_cell])


## Takes hold of the exact items a produce job will consume, so no other job can
## take them while it walks over and works.
func _claim_inputs(job: Job) -> void:
	var inputs: Variant = gather_inputs(job)
	if inputs == null:
		return
	job.claimed_inputs = inputs
	for entry in job.claimed_inputs:
		for item: WorldItem in entry.items:
			item.reserved_by = job
			if not job.reserved_items.has(item):
				job.reserved_items.append(item)


## A produce job finished: consume the inputs, spawn the outputs, run effects.
func finish_produce(job: Job, worker: Worker = null) -> void:
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
		if job.reserved_output_for != null and _job_alive(job.reserved_output_for):
			out.reserved_by = job.reserved_output_for
		# Only the order's own dish is tagged with the order: ingredients stay
		# shareable between orders (tagging them would lock the pantry per order).
		pass  # BISECT: tagging disabled
	job.state = Job.State.DONE
	_release_held_items(job)
	_log("%s -> %s @ %s" % [job.recipe.display_name, job.recipe.output, cell])
	work_finished.emit(worker, job)
	if job.recipe.effect == &"complete_order" and job.order != null:
		orders.complete(job.order)
		order_delivered.emit(job.order, cell)
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
## A finished job lets go of everything it was holding. Without this the slices
## a burger did not use stayed reserved for the burger that just completed, so
## the next order planned a whole new cheese wheel instead of taking one.
func _release_held_items(job: Job) -> void:
	if job == null:
		return
	for item in items.items:
		if item.reserved_by == job:
			item.reserved_by = null


func fail_job(job: Job, reason: String) -> void:
	if job == null:
		return
	board.cancel(job, reason)
	emit_warning("Job %s failed: %s" % [job.step_label(), reason])
	if job.order != null:
		plan_order(job.order)


func drop_carried(item: WorldItem, cell: Vector2i, from_job: Job = null) -> void:
	items.finish_carry(item, cell, kitchen.surface_height(cell))
	item.reserved_by = _landing_holder(from_job)


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
	for station in stations:
		station.work_tiles = _work_tiles_for(station)
	_log("stations: %d" % stations.size())


## The walkable tiles around a station, where a worker can stand to use it.
## Zoned stations already know their work cell; this is for the plain pieces.
func _work_tiles_for(station: StationInstance) -> Array[Vector2i]:
	var anchors: Array[Vector2i] = station.work_cells if not station.work_cells.is_empty() else station.cells
	return _work_tiles_around(anchors, station.cells)


## Where a worker could stand to operate this piece if it were placed here — the
## tiles *next to* its work target, exactly like the pathfinder's stand cell.
## Used by the UI while dragging a piece or previewing one from the shop.
func preview_work_tiles(def: FurnitureDef, anchor: Vector2i, steps: int) -> Array[Vector2i]:
	if def == null or def.tags.is_empty() or def.has_tag(&"worker"):
		return []
	var own := def.cells(anchor, steps)
	var anchors: Array[Vector2i] = []
	for zone in def.zones:
		if str(zone.get("role", "")) == "work":
			var offset: Vector2i = zone.get("offset", Vector2i.ZERO)
			anchors.append(anchor + FurnitureDef.rotated_offset(offset, steps))
	if anchors.is_empty():
		anchors = own
	return _work_tiles_around(anchors, own)


## Walkable tiles beside [param anchors], excluding the piece's own cells. The
## worker always stands NEXT to what it operates, never on it.
func _work_tiles_around(anchors: Array[Vector2i], own: Array[Vector2i]) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if kitchen == null or kitchen.data == null:
		return out
	for cell: Vector2i in anchors:
		for step in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = cell + step
			if out.has(n) or own.has(n):
				continue
			if not kitchen.is_walkable(n) or not kitchen.can_cross(cell, n):
				continue
			out.append(n)
	return out


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
		if _eaten_posts.has(cell):
			continue
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


## An order whose jobs all vanished (a cancelled or failed job) would sit silent
## until it timed out. Every couple of seconds, re-plan an order that has no
## pending or active work left, so a lost job can never strand an order.
func _retry_stalled_orders() -> void:
	for order in orders.orders:
		if order.state != Order.State.IN_PROGRESS and order.state != Order.State.WAITING:
			_stalled_seen.erase(order.id)
			continue
		if _has_live_jobs(order):
			# Give it a grace period: an order is only "stalled" after it has had
			# no work for a few checks (the tick between the last job finishing
			# and the order completing looks the same as a stall).
			_stalled_seen.erase(order.id)
			continue
		var seen := int(_stalled_seen.get(order.id, 0)) + 1
		_stalled_seen[order.id] = seen
		if seen < 3:
			continue
		if plan_order(order):
			order.state = Order.State.IN_PROGRESS
			_log("re-planned stalled order %d" % order.id)
		else:
			order.state = Order.State.UNPLANNABLE
			_log("stalled order %d cannot be re-planned" % order.id)


## Who a carried item belongs to the moment it lands: the carry's parent when
## that job is still working (a carry planned FOR its consumer), or — for a
## follow-up carry, whose parent is the producer and is already done — the
## consumer the producer made the item for (reserved_output_for). Handing it to
## nobody here is what let another order's plan steal it ("a job lost its
## inputs").
func _landing_holder(job: Job) -> Job:
	if job == null or job.parent == null:
		return null
	if _job_alive(job.parent):
		return job.parent
	if job.parent.reserved_output_for != null and _job_alive(job.parent.reserved_output_for):
		return job.parent.reserved_output_for
	return null


## A job that is still on the board and still wants something.
func _job_alive(job: Job) -> bool:
	if job == null:
		return false
	if not board.jobs.has(job):
		return false
	return job.state == Job.State.PENDING or job.state == Job.State.ACTIVE


## Items held by a plan that no longer exists become free again. This is the net
## that makes a lost job self-healing instead of a permanent lock.
func _sweep_stale_reservations() -> void:
	for item in items.items:
		if item.reserved_by != null and not _job_alive(item.reserved_by):
			item.reserved_by = null


func _has_live_jobs(order: Order) -> bool:
	for job in board.jobs:
		if job.order != order:
			continue
		if job.state == Job.State.PENDING or job.state == Job.State.ACTIVE:
			return true
	return false


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
