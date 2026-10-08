class_name Service
extends Node3D
## Owns the simulated kitchen: items, stations, the job board, the planner and
## the orders.
##
## The simulation advances in fixed TICKS (see [member ticks_per_second]); every
## timed thing (recipes, carries, order limits) is counted in ticks, so a run is
## deterministic and can be replayed at any speed. Presentation is separate: item
## views interpolate in real time (see [WorldItem]), never per tick.
##
## Jobs are executed by [PlaceholderExecutor] for now — a stand-in for the real
## chibi workers, loudly marked as such.

signal warning(text: String)
signal state_changed

@export var kitchen: Kitchen

@export_group("Simulation")
## Fixed simulation rate. All durations in the game are ticks.
@export var ticks_per_second := 10
## 1 = real time, 0 = manual stepping (tests), higher = fast-forward.
@export var sim_speed := 1.0
## Safety valve so a slow frame cannot spiral into hundreds of ticks.
@export var max_ticks_per_frame := 5

@export_group("Job picking")
@export var age_weight := 1.0
@export var distance_weight := 0.15

@export_group("Orders")
@export var starting_trays := 3
@export var spawn_start_order := true

var items: ItemManager
var orders: OrderManager
var board := JobBoard.new()
var planner := Planner.new()
var stations: Array[StationInstance] = []
## PLACEHOLDER: stands in for real workers until they are implemented.
var executor: PlaceholderExecutor

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
	executor = PlaceholderExecutor.new()
	executor.items = items
	executor.orders = orders
	executor.board = board
	executor.kitchen = kitchen
	executor.log = _log
	executor.warn = emit_warning
	executor.replan = plan_order
	print(executor.banner())
	if kitchen != null:
		kitchen.layout_rebuilt.connect(_on_layout_changed)
		kitchen.layout_edited.connect(_on_layout_changed)
	rebuild_stations()
	_seed_trays()
	if spawn_start_order:
		request_order()


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
	for job in board.jobs:
		print("  job #%d %s state=%d finish=%d %s" % [job.id, job.describe(), job.state, job.finish_tick, job.fail_reason])
	for item in items.items:
		print("  item %s @ %s reserved=%s" % [item.describe(), item.cell, item.reserved_by != null])


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


## One tick of the world: finish due jobs, start ready ones, retry stuck orders.
func tick_once() -> void:
	tick += 1
	orders.tick_once()
	executor.tick_seconds = tick_seconds()
	executor.age_weight = age_weight
	executor.distance_weight = distance_weight
	executor.tick(tick)
	if ticks_per_second > 0 and tick % maxi(ticks_per_second * 2, 1) == 0:
		_retry_unplannable()
	state_changed.emit()


## Test / cutscene helper: advance an exact number of ticks, ignoring real time.
func run_ticks(count: int) -> void:
	for i in count:
		tick_once()


## Advances ticks until no job is pending or running (or the cap is hit) and
## returns how many ticks that took. Deterministic.
func run_until_idle(max_ticks := 20000) -> int:
	var spent := 0
	while spent < max_ticks:
		if board.pending_count() == 0 and not executor.has_active_jobs():
			break
		tick_once()
		spent += 1
	return spent


func has_active_jobs() -> bool:
	return executor.has_active_jobs()


func request_order(dish: StringName = &"burger") -> Order:
	return orders.spawn(dish)


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


## Stations come from placed furniture (anything with capability tags) plus the
## structural intake / delivery points.
func rebuild_stations() -> void:
	stations.clear()
	if kitchen == null or kitchen.data == null:
		return
	for inst in kitchen.get_furniture_instances():
		if inst.def.tags.is_empty():
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
	items.spawn(ItemCatalog.find(&"tray"), intake.input_cell(), starting_trays,
		{}, kitchen.surface_height(intake.input_cell()))
	_log("seeded %d trays at the intake" % starting_trays)


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


func _on_warning(text: String) -> void:
	emit_warning(text)


func _log(text: String) -> void:
	events.append("[t%5d] %s" % [tick, text])
	if events.size() > 200:
		events.pop_front()


func status_text() -> String:
	var active := orders.active_orders()
	return "tick %d | orders %d | money %d | jobs %d | items %d" % [
		tick, active.size(), orders.money, board.pending_count(), items.items.size()
	]
