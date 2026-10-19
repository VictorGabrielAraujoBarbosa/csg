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
## Every day after the scripted opening adds one order but no extra time: the
## arrivals bunch up and the queue grows faster than any kitchen can clear it.
@export var ticks_per_day_extra := 0
@export var base_orders := 3
@export var orders_per_day_extra := 1
@export var max_modifiers := 2
@export var base_seed := 20261012
@export var menu: Array[StringName] = [&"burger", &"salad", &"fries"]

@export_group("Economy & loss")
## Enough to buy the pieces a starter kitchen is missing — a sink, a shelf and
## a fridge are $320 of it — with a little left over to experiment.
@export var starting_money := 400
## How long an order may wait on day one, and how much of that is taken away
## every day after: the squeeze is felt as a tightening countdown, not just as a
## longer queue.
@export var order_time_limit_ticks := 800
@export var order_time_limit_per_day := -70
## Never go below this, or a single dish becomes impossible to serve at all.
@export var order_time_limit_floor := 160

@export_group("Horror")
## A lost day ends with the customers breaking in and eating the staff.
@export var horror_enabled := true
## Customers = mob_base + day, capped at mob_max.
@export var mob_base := 2
@export var mob_max := 6
## Safety cap on the attack, in ticks; then the day closes anyway.
@export var horror_timeout_ticks := 900
## What it costs to replace one eaten worker. If the purse cannot cover the
## whole crew, the restaurant closes for good.
@export var rehire_cost := 40

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
## Set when the run is over (the purse could not rehire the eaten staff).
var run_over := false

var _horror_deadline := 0
## The authored order limit, remembered so [method reset_run] can undo the
## squeeze a long run has applied to it.
var _base_order_time_limit := 0


func _ready() -> void:
	if service == null:
		service = get_node_or_null("../Service") as Service
	if kitchen == null:
		kitchen = get_node_or_null("../Kitchen") as Kitchen
	_base_order_time_limit = order_time_limit_ticks
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
## the coming day may ask for, and at least one worker is on shift. The reasons
## are the blunt, player-facing sentences of [method _tidy_reasons].
func can_start_day() -> Array[String]:
	var reasons: Array[String] = []
	if service == null:
		return ["no service"]
	if service.workers.is_empty():
		reasons.append("no worker post placed")
	# A day is only winnable if the tray cycle can close: the dry run plans each
	# order on its own, finds a free tray and never needs the wash, so a kitchen
	# with no sink passed the gate and then strangled itself once the pool ran
	# out. Trays come back only through a washing station.
	if not _has_station_tag(&"washing"):
		reasons.append("no washing station: dirty trays can never come back")
	var preview := _make_plan(day + 1)
	for arrival: Dictionary in preview.arrivals:
		for text: String in service.can_serve(arrival["dish"], arrival["adds"], arrival["removes"]):
			if not reasons.has(text):
				reasons.append(text)
	return _tidy_reasons(reasons)


## The dry run explains every missing link in planner speak ("no storage station
## to get Bread from", "cannot make Burger: no way to provide bread", ...). The
## player only ever sees the blunt form: what the kitchen cannot make and the
## shop piece that fixes it. One line per missing thing (deduped by the missing
## tag), never the cascade that follows from it.
static func _tidy_reasons(reasons: Array[String]) -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for text in reasons:
		var key := _reason_key(text)
		if seen.has(key):
			continue
		seen[key] = true
		var line := _blunt_reason(text)
		if not line.is_empty():
			out.append(line)
	# A refusal must always say something: the gate is never allowed to look
	# happy while the dry run failed.
	if out.is_empty() and not reasons.is_empty():
		out.append("Your kitchen can't serve the menu — something is missing.")
	return out


## What a raw dry-run line is about, for dedup: the missing station tag (or a
## structural thing like staff / the tray cycle).
static func _reason_key(text: String) -> String:
	if text.contains("worker"):
		return "workers"
	if text.contains("washing"):
		return "washing"
	if text.contains("delivery point"):
		return "delivery"
	var tag := _missing_tag(text)
	return "tag:" + tag if not tag.is_empty() else "other:" + text


## One raw dry-run line as the player sees it: "Your kitchen can't make X — you
## need a Y.", Y being the shop piece(s) that carry the missing station tag.
static func _blunt_reason(text: String) -> String:
	if text.contains("worker"):
		return "Your kitchen has no staff — place a Worker Post."
	if text.contains("washing"):
		return "Your kitchen can't wash trays — you need a Sink."
	if text.contains("delivery point"):
		return "Your kitchen has no delivery point — orders can never be handed over."
	if text.contains("no free "):
		# "no free assembly station to make Burger": the station exists, so this
		# is the planner echoing a failure further up the tree (or a station that
		# is busy, which cannot happen while the build phase is idle). The real
		# reason is its own line; this one is noise.
		return ""
	var tag := _missing_tag(text)
	var item := _missing_item(text)
	if tag.is_empty() or item.is_empty():
		# The cascade ("cannot make Burger: no way to provide bread") and any
		# other planner-internal line: the structural reason already covers it.
		return ""
	var fixers := _fixer_phrase(StringName(tag))
	if fixers.is_empty():
		return "Your kitchen can't make %s — this map has no %s station." % [item, tag]
	return "Your kitchen can't make %s — you need %s." % [item, fixers]


## The station tag a planner warning names, or "" when it names none.
static func _missing_tag(text: String) -> String:
	for marker in [" station to get ", " station to make ", " station to plate "]:
		var idx := text.find(marker)
		if idx < 0:
			continue
		var head := text.substr(0, idx).trim_prefix("no ")
		head = head.trim_prefix("free ")
		return head.split(",")[0].strip_edges()
	return ""


## The item (or dish) a planner warning names, or "" when it names none.
static func _missing_item(text: String) -> String:
	for marker in [" station to get ", " station to make ", " station to plate "]:
		var idx := text.find(marker)
		if idx < 0:
			continue
		return text.substr(idx + marker.length()).strip_edges().trim_suffix(" from")
	return ""


## The shop pieces that fix a missing station tag, as shop copy ("a Shelf",
## "a Cutting Table or a Plating Station"). "" when nothing on sale carries it
## (a structural point like the intake, or a map-only piece).
static func _fixer_phrase(tag: StringName) -> String:
	var names := PackedStringArray()
	for def in FurnitureCatalog.shop_items():
		if def.has_tag(tag):
			names.append(_with_article(def.display_name))
	if names.is_empty():
		return ""
	if names.size() == 1:
		return names[0]
	var head := PackedStringArray()
	for i in names.size() - 1:
		head.append(names[i])
	return "%s or %s" % [", ".join(head), names[names.size() - 1]]


static func _with_article(name: String) -> String:
	var first := name.substr(0, 1).to_lower()
	return ("an " if "aeiou".contains(first) else "a ") + name


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
	order_time_limit_ticks = maxi(
		order_time_limit_ticks + order_time_limit_per_day * (day - 1), order_time_limit_floor)
	# A new day: the windows are repaired and the eaten staff is back on shift.
	if kitchen != null:
		kitchen.clear_broken_edges()
	if service != null:
		service.stop_mob()
		service.clear_eaten_posts()
	service.watchdog_enabled = true
	phase = Phase.DAY
	phase_changed.emit(phase)
	print("[day] day %d starts: %d orders over %d ticks (seed %d)" % [
		day, plan.arrivals.size(), plan.max_ticks, plan.seed_value])
	return true


func finish_day() -> void:
	# Leave the day phase (used by the summary screen's button).
	if phase == Phase.SUMMARY:
		if run_over:
			return
		if service != null:
			service.reset_after_day()
			# Rehiring the staff the customers ate costs money; if the purse
			# cannot cover it, the run is over.
			var eaten := service.eaten_count()
			var fee := eaten * rehire_cost
			if fee > 0 and not service.orders.try_spend(fee):
				run_over = true
				summary["run_over"] = true
				summary["rehire_fee"] = fee
				day_finished.emit(summary)
				return
			service.clear_eaten_posts()
		if kitchen != null:
			kitchen.clear_broken_edges()
		phase = Phase.BUILD
		phase_changed.emit(phase)


## Puts the run back to the state the game boots in. A lost day is the end of
## the run (the UI plays its cards and returns to the main menu), so nothing of
## it may leak into the next one: day zero, the purse refilled, the windows
## repaired, the staff back on shift and no leftover summary. A won day never
## comes through here — its summary keeps the "Next day" flow.
func reset_run() -> void:
	day = 0
	phase = Phase.BUILD
	plan = null
	next_arrival = 0
	day_start_tick = 0
	served = 0
	lost = false
	loss_reason = ""
	horror = false
	run_over = false
	summary = {}
	order_time_limit_ticks = _base_order_time_limit
	if service != null:
		service.stop_mob()
		service.clear_eaten_posts()
		service.watchdog_enabled = false
		service.reset_after_day()
		service.orders.money = starting_money
	if kitchen != null:
		kitchen.clear_broken_edges()
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


func _has_station_tag(tag: StringName) -> bool:
	for station in service.stations:
		if station.has_tag(tag):
			return true
	return false


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
	service.watchdog_enabled = false
	summary = {
		"day": day,
		"served": served,
		"money": service.orders.money,
		"lost": lost,
		"reason": loss_reason,
		"eaten": service.eaten_count(),
		"rehire_fee": service.eaten_count() * rehire_cost,
	}
	phase = Phase.SUMMARY
	phase_changed.emit(phase)
	day_finished.emit(summary)
	print("[day] day %d %s (served %d, money $%d)%s" % [
		day, "lost" if lost else "complete", served, service.orders.money,
		" — " + loss_reason if lost else ""])


func _on_order_completed(_order: Order) -> void:
	served += 1
