class_name Planner
extends RefCounted
## Expands an order into jobs by lazily resolving its recipe tree.
##
## Resolution rules, per requirement:
##   1. a free (unreserved) matching item exists  -> reserve it + transfer job
##   2. it is a base ingredient                   -> "take from storage" job + transfer
##   3. a recipe makes it and a capable station exists -> produce job, and the same
##      rules are applied recursively to that recipe's own inputs
##   4. otherwise                                 -> warn (missing station / missing
##      ingredient) and fail the plan
##
## A cycle guard breaks the tray loop (wash -> dirty -> deliver -> plate ->
## pack -> tray -> wash) when there is genuinely no tray to be had, so the
## player gets "no way to provide tray" instead of an infinite expansion.

var items: ItemManager
var stations: Array[StationInstance] = []
var board: JobBoard
var warnings: Array[String] = []


func plan_order(order: Order, now: float) -> bool:
	board.cancel_for_order(order)
	var delivery := _find_station(&"delivery", Vector2i.ZERO)
	if delivery == null:
		_warn("no delivery point in the kitchen")
		return false
	var deliver := RecipeCatalog.find(&"deliver")
	if deliver == null:
		_warn("no 'deliver' recipe")
		return false
	var job := _plan_recipe(deliver, delivery, order, Job.NO_CELL, null, [], now)
	if job == null:
		return false
	order.state = Order.State.IN_PROGRESS
	return true


func _plan_recipe(recipe: RecipeDef, station: StationInstance, order: Order,
		deliver_to: Vector2i, parent: Job, chain: Array, now: float) -> Job:
	if chain.has(recipe.id):
		return null
	var next_chain := chain.duplicate()
	next_chain.append(recipe.id)
	var job := Job.new()
	job.kind = Job.Kind.PRODUCE
	job.recipe = recipe
	job.station = station
	job.order = order
	job.parent = parent
	job.deliver_to = deliver_to
	job.location = station.origin()
	job.created_at = now
	for entry in recipe.inputs:
		var item_id: StringName = entry.get("item", &"")
		var amount := int(entry.get("amount", 1))
		var needs_order: bool = entry.get("needs_order", false)
		var provider := _plan_item(item_id, amount, station.input_cell(), order,
			needs_order, job, next_chain, now)
		if provider == null:
			board.cancel(job, "cannot provide " + String(item_id))
			_warn("cannot make %s: no way to provide %s" % [recipe.display_name, item_id])
			return null
	board.add(job)
	return job


func _plan_item(item_id: StringName, amount: int, target_cell: Vector2i, order: Order,
		needs_order: bool, parent: Job, chain: Array, now: float) -> Job:
	var order_id := order.id if order != null else -1
	var remaining := amount
	var first_job: Job = null
	var guard := 0
	while remaining > 0 and guard < 12:
		guard += 1
		# 1. something already made and free (a whole stack can be reserved)
		var free := items.find_free(item_id, order_id, needs_order, target_cell)
		if free != null:
			var transfer := _make_transfer(free, target_cell, order, parent, now)
			remaining -= 1
			if first_job == null:
				first_job = transfer
			continue
		# 2/3. plan one batch of it
		var made := _plan_one_batch(item_id, target_cell, order, needs_order, parent, chain, now)
		if made == null:
			if first_job == null:
				_warn(_explain_missing(item_id, order_id))
				return null
			# Partial plan: the rest is impossible, but keep what we have so the
			# failure surfaces through the parent job's inputs instead.
			return first_job
		if first_job == null:
			first_job = made
		remaining -= maxi(made.get_meta("yield", 1), 1)
	return first_job


## Plans a single production step for an item (source pull or crafting).
func _plan_one_batch(item_id: StringName, target_cell: Vector2i, order: Order,
		needs_order: bool, parent: Job, chain: Array, now: float) -> Job:
	for recipe in RecipeCatalog.producers_of(item_id):
		var station := _find_station(recipe.station_tag, target_cell)
		if station == null:
			continue
		var job := _plan_recipe(recipe, station, order, target_cell, parent, chain, now)
		if job != null:
			job.set_meta("yield", recipe.output_amount)
			return job
	return null


func _make_transfer(item: WorldItem, target_cell: Vector2i, order: Order, parent: Job, now: float) -> Job:
	var job := Job.new()
	job.kind = Job.Kind.TRANSFER
	job.item = item
	job.target_cell = target_cell
	job.order = order
	job.parent = parent
	job.location = item.cell
	job.created_at = now
	item.reserved_by = job
	board.add(job)
	return job


## Nearest station with the tag, preferring ones that are not already busy.
func _find_station(tag: StringName, near: Vector2i) -> StationInstance:
	var best: StationInstance = null
	var best_dist := 1 << 30
	for station in stations:
		if not station.has_tag(tag):
			continue
		if station.busy_by != null or _station_targeted(station):
			continue
		var dist := absi(station.origin().x - near.x) + absi(station.origin().y - near.y)
		if dist < best_dist:
			best_dist = dist
			best = station
	if best == null:
		# Everything is busy: still allow planning so jobs queue up.
		for station in stations:
			if not station.has_tag(tag):
				continue
			var dist := absi(station.origin().x - near.x) + absi(station.origin().y - near.y)
			if dist < best_dist:
				best_dist = dist
				best = station
	return best


func _station_targeted(station: StationInstance) -> bool:
	for job in board.jobs:
		if job.state == Job.State.PENDING and job.station == station:
			return true
	return false


func _explain_missing(item_id: StringName, order_id: int) -> String:
	var def := ItemCatalog.find(item_id)
	var name := def.display_name if def != null else String(item_id)
	var recipes := RecipeCatalog.producers_of(item_id)
	if recipes.is_empty():
		return "nothing can make %s" % name
	var tags := PackedStringArray()
	for recipe in recipes:
		if not recipe.is_source:
			tags.append(String(recipe.station_tag))
	if tags.is_empty():
		return "no %s station to get %s from" % [String(def.source_tag) if def != null else "?", name]
	for tag in tags:
		if _has_station(StringName(tag)):
			return "no free %s station to make %s" % [tag, name]
	return "no %s station to make %s" % [", ".join(tags), name]


func _has_station(tag: StringName) -> bool:
	for station in stations:
		if station.has_tag(tag):
			return true
	return false


func _warn(text: String) -> void:
	if not warnings.has(text):
		warnings.append(text)
