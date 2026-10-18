class_name RecipeCatalog
## All the recipes in the prototype: the burger line plus the tray cycle
## (pack -> plate -> deliver -> wash).

static var _cache: Dictionary = {}
static var _by_id: Dictionary = {}
static var _source_cache: Dictionary = {}
static var _variants: Dictionary = {}
static var _serves: Dictionary = {}


static func all() -> Dictionary:
	if _cache.is_empty():
		_build()
	return _cache


static func find(id: StringName) -> RecipeDef:
	all()
	return _by_id.get(id)


## Releases the cached resources (called on shutdown so the engine exits clean).
static func clear_caches() -> void:
	_cache.clear()
	_by_id.clear()
	_source_cache.clear()
	_variants.clear()
	_serves.clear()


## A dish recipe with some ingredients removed ("burger with no cheese"), cached
## by variant id. Produced items are stamped with the variant so they only
## satisfy orders that asked for it.
static func variant_of(base_id: StringName, removes: Array) -> RecipeDef:
	var base := find(base_id)
	if base == null:
		# A dish is identified by the ITEM it produces; its recipe may be named
		# differently (make_salad -> salad, fry_fries -> fries). Without this a
		# salad order could never be plated.
		for candidate in producers_of(base_id):
			if candidate.is_source:
				continue
			base = candidate
			break
	if base == null:
		return null
	if removes.is_empty():
		return base
	var ids: Array[StringName] = []
	for id: StringName in removes:
		ids.append(id)
	ids.sort()
	var key := String(base_id) + "__" + _join(ids)
	if _variants.has(key):
		return _variants[key]
	var variant := RecipeDef.new()
	variant.id = StringName(key)
	variant.display_name = base.display_name
	variant.output = base.output
	variant.output_amount = base.output_amount
	variant.station_tag = base.station_tag
	variant.duration_ticks = base.duration_ticks
	variant.effect = base.effect
	variant.stamp = base.stamp
	variant.variant_id = variant.id
	var removed_items: Array[StringName] = []
	for id: StringName in ids:
		var mod := ModifierCatalog.find(id)
		if mod != null:
			removed_items.append(mod.item)
	var kept: Array = []
	for entry in base.inputs:
		if not removed_items.has(StringName(entry.get("item", &""))):
			kept.append(entry)
	variant.inputs = kept
	_variants[key] = variant
	_by_id[variant.id] = variant
	return variant


## The per-order "plate this dish with these extras" recipe at the assembly
## table, cached by (variant, add-ons). Its tray input matches this order.
static func serve_recipe_for(order: Order) -> RecipeDef:
	var variant := variant_of(order.recipe_id, order.removes)
	var dish_id := variant.variant_id
	var adds: Array[StringName] = []
	for id: StringName in order.adds:
		adds.append(id)
	adds.sort()
	var key := "serve__%s__%s" % [dish_id, _join(adds)]
	if _serves.has(key):
		return _serves[key]
	var recipe := RecipeDef.new()
	recipe.id = StringName(key)
	recipe.display_name = "Plate Dish"
	recipe.output = &"tray_with_finished_order"
	recipe.station_tag = &"assembly"
	recipe.duration_ticks = 10
	recipe.stamp = &"order_dish"
	var inputs: Array = [{
		"item": &"tray_with_order",
		"amount": 1,
		"payload_match": {"order": "$order"},
	}, {
		"item": variant.output,
		"amount": 1,
		"payload_match": {"variant": String(variant.variant_id)},
	}]
	for id: StringName in adds:
		var mod := ModifierCatalog.find(id)
		if mod != null and mod.kind == ModifierDef.Kind.ADD:
			inputs.append({"item": mod.item, "amount": 1})
	recipe.inputs = inputs
	_serves[key] = recipe
	_by_id[recipe.id] = recipe
	return recipe


static func _join(ids: Array[StringName]) -> String:
	var parts := PackedStringArray()
	for id: StringName in ids:
		parts.append(String(id))
	return "none" if parts.is_empty() else "_".join(parts)


## The (synthetic, one per base ingredient) "take from storage" recipe.
static func source_for(item_id: StringName) -> RecipeDef:
	all()
	if _source_cache.has(item_id):
		return _source_cache[item_id]
	var def := ItemCatalog.find(item_id)
	if def == null or not def.is_base:
		return null
	var recipe := RecipeDef.new()
	recipe.id = StringName("take_" + String(def.id))
	recipe.display_name = "Take " + def.display_name
	recipe.output = def.id
	recipe.station_tag = def.source_tag
	recipe.duration_ticks = 10
	recipe.is_source = true
	_source_cache[item_id] = recipe
	return recipe


## Any recipe that produces [param item_id], preferring non-source ones.
static func producers_of(item_id: StringName) -> Array[RecipeDef]:
	all()
	var out: Array[RecipeDef] = []
	for recipe in _cache.values():
		if recipe.output == item_id:
			out.append(recipe)
	var synthetic := source_for(item_id)
	if synthetic != null:
		out.append(synthetic)
	return out


static func _build() -> void:
	_cache.clear()
	_by_id.clear()
	_source_cache.clear()

	_make("pack_order", "Pack Order", &"tray_with_order", 1,
		[{"item": &"tray", "amount": 1}], &"intake", 10, &"", &"order")
	_make("cook_patty", "Cook Patty", &"patty_cooked", 1,
		[{"item": &"patty_raw", "amount": 1}], &"cooking", 40)
	_make("fry_fries", "Fry Potatoes", &"fries", 2,
		[{"item": &"potato", "amount": 2}], &"frying", 30)
	_make("make_salad", "Make Salad", &"salad", 2,
		[{"item": &"tomato", "amount": 2}, {"item": &"lettuce", "amount": 1}], &"prep", 30)
	_make("slice_cheese", "Slice Cheese", &"cheese_slice", 6,
		[{"item": &"cheese", "amount": 1}], &"prep", 30)
	_make("burger", "Burger", &"burger", 1,
		[{"item": &"bread", "amount": 1}, {"item": &"patty_cooked", "amount": 1},
		 {"item": &"salad", "amount": 1}, {"item": &"cheese_slice", "amount": 1}], &"assembly", 20)
	_make("deliver", "Hand Over", &"tray_dirty", 1,
		[{"item": &"tray_with_finished_order", "amount": 1, "payload_match": {"order": "$order"}}],
		&"delivery", 10, &"complete_order")
	_make("wash", "Wash Tray", &"tray", 1,
		[{"item": &"tray_dirty", "amount": 1}], &"washing", 30)


static func _make(id: String, name: String, output: StringName, output_amount: int,
		inputs: Array, station: StringName, duration_ticks: int,
		effect := &"", stamp := &"") -> void:
	var recipe := RecipeDef.new()
	recipe.id = StringName(id)
	recipe.display_name = name
	recipe.output = output
	recipe.output_amount = output_amount
	recipe.inputs = inputs
	recipe.station_tag = station
	recipe.duration_ticks = duration_ticks
	recipe.effect = effect
	recipe.stamp = stamp
	_cache[recipe.id] = recipe
	_by_id[recipe.id] = recipe
