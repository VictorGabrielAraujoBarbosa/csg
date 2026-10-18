class_name DayPlan
extends RefCounted
## One day's schedule, generated from (day number, seed) so every day is
## reproducible: arrivals are spread over the day with a deterministic jitter,
## each rolling a dish and 0..max_modifiers modifiers from a seeded RNG.

var day := 1
var seed_value := 0
## The day's nominal length; it extends past this only while orders are pending.
var max_ticks := 600
## [{tick: int, dish: StringName, adds: Array[StringName], removes: Array[StringName]}]
var arrivals: Array = []


static func generate(day_number: int, seed_value_in: int, menu: Array, modifier_ids: Array,
		order_count: int, day_ticks: int, max_mods: int) -> DayPlan:
	var plan := DayPlan.new()
	plan.day = day_number
	plan.seed_value = seed_value_in
	plan.max_ticks = maxi(day_ticks, 1)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value_in
	var count := maxi(order_count, 1)
	for i in count:
		var slot := float(i + 0.5) / float(count)
		var jitter := rng.randf_range(-0.12, 0.12)
		var tick := int(clampf(slot + jitter, 0.02, 0.98) * float(plan.max_ticks))
		var dish: StringName = &"burger"
		if not menu.is_empty():
			dish = menu[rng.randi_range(0, menu.size() - 1)]
		var adds: Array[StringName] = []
		var removes: Array[StringName] = []
		var touched: Array[StringName] = []
		for id: StringName in _roll_modifiers(rng, modifier_ids, max_mods):
			var def := ModifierCatalog.find(id)
			if def == null:
				continue
			# "+ extra cheese" and "- no cheese" on one ticket is nonsense: a
			# modifier whose ingredient is already spoken for is skipped. The
			# same goes for a modifier the dish cannot carry at all ("- no
			# salad" on a salad).
			if touched.has(def.item) or not ModifierCatalog.applies_to(dish, id):
				continue
			touched.append(def.item)
			if def.kind == ModifierDef.Kind.ADD:
				adds.append(id)
			else:
				removes.append(id)
		plan.arrivals.append({"tick": tick, "dish": dish, "adds": adds, "removes": removes})
	plan.arrivals.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["tick"]) < int(b["tick"]))
	return plan


static func _roll_modifiers(rng: RandomNumberGenerator, ids: Array, max_mods: int) -> Array[StringName]:
	var pool: Array[StringName] = []
	for id: StringName in ids:
		pool.append(id)
	var out: Array[StringName] = []
	var count := rng.randi_range(0, maxi(max_mods, 0))
	while out.size() < count and not pool.is_empty():
		var index := rng.randi_range(0, pool.size() - 1)
		out.append(pool[index])
		pool.remove_at(index)
	return out
