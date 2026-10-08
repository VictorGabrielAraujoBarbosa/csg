class_name PlaceholderExecutor
extends RefCounted
## ⚠⚠⚠  PLACEHOLDER — NOT THE REAL GAME  ⚠⚠⚠
##
## This class does the work until chibi workers exist. It claims ready jobs from
## the job board and finishes them after the recipe's tick duration. Nothing
## walks: "carrying" means the item view glides from A to B over the carry time
## while the simulation counts ticks.
##
## Real workers will claim the *same* ready jobs from the same board and walk to
## the stations, replacing this file entirely. When that happens: delete this
## class, remove [member Service.executor], and drop the [PLACEHOLDER] notes in
## README.md and AGENTS.md.
##
## It takes its dependencies as plain fields (no Service reference) so the two
## classes do not form a script cycle.

## Stands in for "how many workers are on shift".
var parallel_jobs := 3
## Ticks an item spends "in transit" (the view interpolates over that time).
var carry_ticks := 6

# Dependencies, wired by Service.
var items: ItemManager
var orders: OrderManager
var board: JobBoard
var kitchen: Kitchen
var log: Callable
var warn: Callable
var replan: Callable
var tick_seconds := 0.1
var age_weight := 1.0
var distance_weight := 0.15


func banner() -> String:
	return "[service] PLACEHOLDER EXECUTOR active (%d parallel jobs) — jobs teleport between stations; real chibi workers are not implemented yet" % parallel_jobs


func has_active_jobs() -> bool:
	for job in board.jobs:
		if job.state == Job.State.ACTIVE:
			return true
	return false


func active_count() -> int:
	var count := 0
	for job in board.jobs:
		if job.state == Job.State.ACTIVE:
			count += 1
	return count


## One simulation tick: finish what is due, then start what is ready.
func tick(now: int) -> void:
	_complete_due(now)
	_start_ready(now)


func _complete_due(now: int) -> void:
	for job in board.jobs:
		if job.state == Job.State.ACTIVE and job.finish_tick <= now:
			if job.kind == Job.Kind.TRANSFER:
				_finish_transfer(job)
			else:
				_finish_produce(job)
	board.cleanup()


func _start_ready(now: int) -> void:
	var guard := 0
	while active_count() < parallel_jobs and guard < 32:
		guard += 1
		var job := board.best_ready(Vector2i.ZERO, _job_ready, now, age_weight, distance_weight)
		if job == null:
			return
		_start(job, now)


func _start(job: Job, now: int) -> void:
	job.state = Job.State.ACTIVE
	job.started_tick = now
	if job.kind == Job.Kind.TRANSFER:
		job.finish_tick = now + carry_ticks
		# Presentation: glide the item across the kitchen while ticks pass.
		items.begin_carry(job.item, job.target_cell,
			kitchen.surface_height(job.target_cell), float(carry_ticks) * tick_seconds)
		log.call("carry %s -> %s" % [job.item.def.id, job.target_cell])
	else:
		job.finish_tick = now + maxi(job.recipe.duration_ticks, 1)
		job.station.busy_by = job
		log.call("%s started @ %s" % [job.recipe.display_name, job.station.origin()])


func _finish_transfer(job: Job) -> void:
	var item := job.item
	if item == null or not items.items.has(item):
		job.state = Job.State.FAILED
		job.fail_reason = "item vanished"
		warn.call("A carry job lost its item")
		if job.order != null:
			replan.call(job.order)
		return
	item.reserved_by = null
	items.finish_carry(item, job.target_cell, kitchen.surface_height(job.target_cell))
	job.state = Job.State.DONE
	log.call("carried %s -> %s" % [item.def.id, job.target_cell])


func _finish_produce(job: Job) -> void:
	job.station.busy_by = null
	var inputs: Variant = _gather_inputs(job)
	if inputs == null:
		job.state = Job.State.FAILED
		job.fail_reason = "inputs missing"
		warn.call("A job lost its inputs (%s)" % job.recipe.display_name)
		if job.order != null:
			replan.call(job.order)
		return
	var entries: Array = inputs
	for entry in entries:
		var left: int = entry.amount
		for item: WorldItem in entry.items:
			if left <= 0:
				break
			var take := mini(item.amount, left)
			items.consume(item, take)
			left -= take
	var out_def := ItemCatalog.find(job.recipe.output)
	var cell := job.station.output_cell()
	var out := items.spawn(out_def, cell, job.recipe.output_amount,
		_payload_for(job, entries), kitchen.surface_height(cell))
	job.state = Job.State.DONE
	log.call("%s -> %dx %s @ %s" % [job.recipe.display_name, job.recipe.output_amount, job.recipe.output, cell])
	if job.recipe.effect == &"complete_order" and job.order != null:
		orders.complete(job.order)
	if job.deliver_to != Job.NO_CELL:
		var follow := Job.new()
		follow.kind = Job.Kind.TRANSFER
		follow.item = out
		follow.target_cell = job.deliver_to
		follow.order = job.order
		follow.parent = job
		follow.location = out.cell
		follow.created_at = job.finish_tick
		out.reserved_by = follow
		board.add(follow)


func _job_ready(job: Job) -> bool:
	if job.kind == Job.Kind.TRANSFER:
		if job.item == null or not items.items.has(job.item):
			return false
		return job.item.reserved_by == null or job.item.reserved_by == job
	if job.station == null:
		return false
	if job.station.busy_by != null and job.station.busy_by != job:
		return false
	return _gather_inputs(job) != null


## The items that satisfy a produce job's inputs, or null if they are not all
## sitting on the station's input cells yet. Amounts may be spread over several
## stacks (2 tomatoes can be two stacks of one).
func _gather_inputs(job: Job) -> Variant:
	var order_id := job.order.id if job.order != null else -1
	var found: Array = []
	for entry in job.recipe.inputs:
		var item_id: StringName = entry.get("item", &"")
		var need := int(entry.get("amount", 1))
		var needs_order: bool = entry.get("needs_order", false)
		var collected: Array[WorldItem] = []
		var total := 0
		for cell in job.station.input_cells:
			for item in items.items_at(cell):
				if item.reserved_by != null and item.reserved_by != job:
					continue
				if item.matches(item_id, order_id, needs_order):
					collected.append(item)
					total += item.amount
					if total >= need:
						break
			if total >= need:
				break
		if total < need:
			return null
		found.append({"items": collected, "amount": need, "needs_order": needs_order})
	return found


## Payload stamping: "order" marks a tray with its order; "order_dish" copies
## the order from the needs_order input and records which dish is on the tray.
func _payload_for(job: Job, entries: Array) -> Dictionary:
	var payload := {}
	match String(job.recipe.stamp):
		"order":
			if job.order != null:
				payload["order"] = job.order.id
		"order_dish":
			for entry in entries:
				if entry.needs_order and not (entry.items as Array).is_empty():
					payload = ((entry.items as Array)[0] as WorldItem).payload.duplicate()
			for entry in entries:
				if not entry.needs_order and not (entry.items as Array).is_empty():
					payload["dish"] = ((entry.items as Array)[0] as WorldItem).def.id
	return payload
