class_name OrderManager
extends Node
## Keeps the order queue and the money. This prototype spawns infinite burger
## orders (one at start, one more every time an order is handed over).
##
## Not implemented yet (documented in README/AGENTS): arrival by day timestamps,
## per-second chance rolls or periodic top-ups; losing when the queue overflows
## or an order times out. The data for those rules exists here so they can be
## switched on without rework.

signal order_added(order: Order)
signal order_completed(order: Order)
signal order_failed(order: Order, reason: String)
signal warning(text: String)
signal changed

@export var dish_id: StringName = &"burger"
@export var reward_per_order := 30
@export var max_pending := 5
## 0 = no time limit (the prototype has none).
@export var time_limit_ticks := 0
@export var start_orders := 1
@export var arrive_on_turn_in := true

var orders: Array[Order] = []
var completed_count := 0
var failed_count := 0
var money := 0

var _next_id := 1
var _tick := 0


func spawn(dish: StringName = dish_id, order_adds: Array = [], order_removes: Array = []) -> Order:
	var order := Order.new()
	order.id = _next_id
	_next_id += 1
	order.recipe_id = dish
	order.created_tick = _tick
	for id: StringName in order_adds:
		order.adds.append(id)
	for id: StringName in order_removes:
		order.removes.append(id)
	var recipe := RecipeCatalog.find(dish)
	order.dish_name = recipe.display_name if recipe != null else String(dish)
	order.variant = RecipeCatalog.variant_of(dish, order.removes).variant_id
	order.reward = reward_per_order
	if time_limit_ticks > 0:
		order.deadline_tick = _tick + time_limit_ticks
	orders.append(order)
	order_added.emit(order)
	changed.emit()
	var mods := PackedStringArray()
	for id: StringName in order.adds:
		mods.append(ModifierCatalog.label(id))
	for id: StringName in order.removes:
		mods.append(ModifierCatalog.label(id))
	print("[order] new #%d %s %s" % [order.id, order.dish_name, " ".join(mods)])
	return order


func complete(order: Order) -> void:
	if order == null or not order.is_active():
		return
	order.state = Order.State.COMPLETED
	completed_count += 1
	money += order.reward
	order_completed.emit(order)
	changed.emit()
	print("[order] completed #%d %s (+$%d, total $%d)" % [order.id, order.dish_name, order.reward, money])
	if arrive_on_turn_in:
		spawn(order.recipe_id)


func fail(order: Order, reason: String) -> void:
	if order == null or not order.is_active():
		return
	order.state = Order.State.FAILED
	failed_count += 1
	order_failed.emit(order, reason)
	warning.emit("Order %d failed: %s" % [order.id, reason])
	changed.emit()


func active_orders() -> Array[Order]:
	var out: Array[Order] = []
	for order in orders:
		if order.is_active():
			out.append(order)
	return out


## Build-phase money helpers (the day controller owns when they are used).
func can_afford(cost: int) -> bool:
	return money >= cost


func try_spend(cost: int) -> bool:
	if money < cost:
		return false
	money -= cost
	changed.emit()
	print("[money] spent $%d (total $%d)" % [cost, money])
	return true


func add_money(amount: int) -> void:
	money += amount
	changed.emit()


## One simulation tick.
func tick_once() -> void:
	_tick += 1
	if time_limit_ticks <= 0:
		return
	for order in orders:
		if order.is_active() and order.deadline_tick > 0 and _tick > order.deadline_tick:
			# Losing on a timeout is not implemented yet; the order just fails.
			fail(order, "took too long")


func tick() -> int:
	return _tick
