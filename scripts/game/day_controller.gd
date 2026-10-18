class_name DayController
extends Node
## The gameplay loop: BUILD -> DAY -> SUMMARY -> BUILD.
##
## Build: the player rearranges and buys; Start Day is gated by a dry-run
## planner check of the whole menu (plus at least one worker post).
## Day: arrivals fire at the ticks the day plan scheduled; the day ends once
## every arrival has fired and no order is pending — or in a loss when too many
## orders pile up / one waits too long. Summary reports and returns to build.

enum Phase { BUILD, DAY, SUMMARY }

signal phase_changed(phase: int)
signal day_finished(summary: Dictionary)
signal reasons_changed(reasons: Array)

@export var service: Service
@export var kitchen: Kitchen

@export_group("Day schedule")
## Day 1 asks `base_orders` orders over `base_day_ticks`; later days add more.
@export var base_day_ticks := 600
## Every day after the scripted opening adds one order but only this many ticks,
## so the queue grows faster than any kitchen can clear it.
@export var ticks_per_day_extra := 60
@export var base_orders := 3
@export var orders_per_day_extra := 1
@export var max_modifiers := 2
@export var base_seed := 20261012
@export var menu: Array[StringName] = [&"burger"]

@export_group("Economy & loss")
@export var starting_money := 250
## An order waiting longer than this loses the day. Generous on purpose: the
## demo should be lost to the queue piling up, not to one slow dish.
@export var order_time_limit_ticks := 800

@export_group("Horror")
## A lost day ends with the customers breaking in and eating the staff.
@export var horror_enabled := true
## Customers = mob_base + day, capped at mob_max.
@export var mob_base := 2
@export var mob_max := 6
## Safety cap on the attack, in ticks; then the day closes anyway.
@export var horror_timeout_ticks := 900

## The hand-authored opening days (no RNG: the demo must play the same way every
## run). Day 1 teaches storage — the venue ships without one — day 2 teaches
## fries (a frying station is required) and day 3 throws everything at once.
const DAY_SCRIPT := [
	{
		"ticks": 600,
		"arrivals": [
			{"tick": 40},
			{"tick": 230},
			{"tick": 430},
		],
	},
	{
		"ticks": 900,
		"arrivals": [
			{"tick": 40},
			{"tick": 220, "adds": [&"add_fries"]},
			{"tick": 420, "adds": [&"add_fries"]},
		],
	},
	{
		"ticks": 950,
		"arrivals": [
			{"tick": 30, "adds": [&"add_cheese"]},
			{"tick": 260, "adds": [&"add_fries"]},
			{"tick": 520, "removes": [&"no_salad"]},
		],
	},
]

var phase := Phase.BUILD
var day := 0
var plan: DayPlan
var next_arrival := 0
var day_start_tick := 0
var served := 0
var lost := false
var loss_reason := ""
var summary: Dictionary = {}
## True while the customers are inside eating the staff.
var horror := false

var _horror_deadline := 0


func _ready() -> void:
	if service == null:
		service = get_node_or_null("../Service") as Service
	if kitchen == null:
		kitchen = get_node_or_null("../Kitchen") as Kitchen
	if service != null:
		service.orders.money = starting_money
		# The controller owns the queue rules, so the manager's own timer is off.
		service.orders.time_limit_ticks = 0
		service.orders.arrive_on_turn_in = false
		service.orders.order_completed.connect(_on_order_completed)
		service.tick_passed.connect(_on_tick)


## Day logic is driven by simulation ticks (not frames), so headless tests can
## step the world manually and get identical results.
func _on_tick(_tick: int) -> void:
	if phase != Phase.DAY:
		return
	if horror:
		if not service.mob_active or service.tick >= _horror_deadline:
			_end_horror()
		return
	_fire_arrivals()
	if _check_loss():
		return
	_check_end()


## The build phase can start when the kitchen can make every dish (and variant)
## the coming day may ask for, and at least one worker is on shift.
func can_start_day() -> Array[String]:
	var reasons: Array[String] = []
	if service == null:
		return ["no service"]
	if service.workers.is_empty():
		reasons.append("no worker post placed")
	var preview := _make_plan(day + 1)
	for arrival: Dictionary in preview.arrivals:
		for text: String in service.can_serve(arrival["dish"], arrival["adds"], arrival["removes"]):
			if not reasons.has(text):
				reasons.append(text)
	return _tidy_reasons(reasons)


## The dry run explains every missing link ("no storage station to get Bread
## from", "cannot make Burger: no way to provide bread", ...). For the player we
## keep the structural reasons (a missing station, no staff) and drop the
## cascade that follows from them.
static func _tidy_reasons(reasons: Array[String]) -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for text in reasons:
		if text.contains("worker post"):
			out.append(text)
			seen["workers"] = true
	var structural: Array[String] = []
	for text in reasons:
		if not text.begins_with("no "):
			continue
		var idx := text.find(" station")
		if idx < 0:
			continue
		var key := text.substr(3, idx - 3)
		if key.begins_with("free "):
			key = key.substr(5)
		if seen.has(key):
			continue
		seen[key] = true
		structural.append(text)
	if structural.is_empty():
		return reasons if not reasons.is_empty() else out
	out.append_array(structural)
	return out


func start_day() -> bool:
	if phase != Phase.BUILD or service == null:
		return false
	day += 1
	plan = _make_plan(day)
	next_arrival = 0
	day_start_tick = service.tick
	served = 0
	lost = false
	loss_reason = ""
	summary = {}
	horror = false
	# A new day: the windows are repaired and the eaten staff is back on shift.
	if kitchen != null:
		kitchen.clear_broken_edges()
	if service != null:
		service.stop_mob()
		service.clear_eaten_posts()
	phase = Phase.DAY
	phase_changed.emit(phase)
	print("[day] day %d starts: %d orders over %d ticks (seed %d)" % [
		day, plan.arrivals.size(), plan.max_ticks, plan.seed_value])
	return true


func finish_day() -> void:
	# Leave the day phase (used by the summary screen's button).
	if phase == Phase.SUMMARY:
		if service != null:
			service.reset_after_day()
			service.clear_eaten_posts()
		if kitchen != null:
			kitchen.clear_broken_edges()
		phase = Phase.BUILD
		phase_changed.emit(phase)


func _make_plan(day_number: int) -> DayPlan:
	if day_number >= 1 and day_number <= DAY_SCRIPT.size():
		return _scripted_plan(day_number)
	var count := base_orders + maxi(day_number - 1, 0) * orders_per_day_extra
	var ticks := base_day_ticks + maxi(day_number - 1, 0) * ticks_per_day_extra
	var modifier_ids: Array[StringName] = []
	for def in ModifierCatalog.all():
		modifier_ids.append(def.id)
	return DayPlan.generate(day_number, base_seed + day_number * 7919, menu,
		modifier_ids, count, ticks, max_modifiers)


## The scripted opening: fixed arrivals, so day 1 and day 2 always teach the same
## lesson (buy storage, then buy a fryer).
func _scripted_plan(day_number: int) -> DayPlan:
	var script: Dictionary = DAY_SCRIPT[day_number - 1]
	var plan := DayPlan.new()
	plan.day = day_number
	plan.seed_value = base_seed + day_number * 7919
	plan.max_ticks = int(script.get("ticks", base_day_ticks))
	var dish: StringName = menu[0] if not menu.is_empty() else &"burger"
	for entry: Dictionary in script.get("arrivals", []):
		plan.arrivals.append({
			"tick": int(entry.get("tick", 0)),
			"dish": dish,
			"adds": entry.get("adds", []),
			"removes": entry.get("removes", []),
		})
	return plan


## One line for the summary card, foreshadowing what the next day brings.
func next_day_hint() -> String:
	match day + 1:
		2:
			return "Tomorrow: fries are on the menu. You will need a frying station."
		3:
			return "Tomorrow: a full menu, and busier than today."
		_:
			return "Tomorrow: busier again." 


func _fire_arrivals() -> void:
	while next_arrival < plan.arrivals.size():
		var arrival: Dictionary = plan.arrivals[next_arrival]
		if service.tick - day_start_tick < int(arrival["tick"]):
			break
		service.request_order(arrival["dish"], arrival["adds"], arrival["removes"])
		next_arrival += 1


func _check_loss() -> bool:
	var active := service.orders.active_orders()
	if active.size() > service.orders.max_pending:
		_lose_day("too many orders waiting")
		return true
	for order in active:
		if service.tick - order.created_tick > order_time_limit_ticks:
			print("[day] order #%d waited %d ticks (limit %d)" % [
				order.id, service.tick - order.created_tick, order_time_limit_ticks])
			_lose_day("an order waited too long")
			return true
	return false


## A lost day is not over yet: the customers break in through the windows and
## eat the staff. The day only closes once the kitchen is empty (or the attack
## times out), so the summary follows the horror instead of interrupting it.
func _lose_day(reason: String) -> void:
	lost = true
	loss_reason = reason
	for order in service.orders.active_orders():
		service.orders.fail(order, reason)
		service.board.cancel_for_order(order)
	if not horror_enabled:
		_finish_day()
		return
	var count := mini(mob_base + day, mob_max)
	var broken: Array[Vector3i] = service.start_mob(count)
	if broken.is_empty():
		_finish_day()
		return
	horror = true
	_horror_deadline = service.tick + horror_timeout_ticks
	print("[day] day %d lost (%s) — %d customers break in through %d window edge(s)" % [
		day, reason, count, broken.size()])


func _end_horror() -> void:
	horror = false
	service.stop_mob()
	_finish_day()


func _check_end() -> void:
	if next_arrival >= plan.arrivals.size() and service.orders.active_orders().is_empty():
		_finish_day()


func _finish_day() -> void:
	if lost:
		# The orders are already failed; the staff may be short a few chibis.
		pass
	summary = {
		"day": day,
		"served": served,
		"money": service.orders.money,
		"lost": lost,
		"reason": loss_reason,
		"eaten": service.eaten_count(),
	}
	phase = Phase.SUMMARY
	phase_changed.emit(phase)
	day_finished.emit(summary)
	print("[day] day %d %s (served %d, money $%d)%s" % [
		day, "lost" if lost else "complete", served, service.orders.money,
		" — " + loss_reason if lost else ""])


func _on_order_completed(_order: Order) -> void:
	served += 1
