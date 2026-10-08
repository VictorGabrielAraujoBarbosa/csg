class_name RecipeCatalog
## All the recipes in the prototype: the burger line plus the tray cycle
## (pack -> plate -> deliver -> wash).

static var _cache: Dictionary = {}
static var _by_id: Dictionary = {}
static var _source_cache: Dictionary = {}


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
	_make("make_salad", "Make Salad", &"salad", 2,
		[{"item": &"tomato", "amount": 2}, {"item": &"lettuce", "amount": 1}], &"prep", 30)
	_make("slice_cheese", "Slice Cheese", &"cheese_slice", 6,
		[{"item": &"cheese", "amount": 1}], &"prep", 30)
	_make("burger", "Burger", &"burger", 1,
		[{"item": &"bread", "amount": 1}, {"item": &"patty_cooked", "amount": 1},
		 {"item": &"salad", "amount": 1}, {"item": &"cheese_slice", "amount": 1}], &"assembly", 20)
	_make("plate", "Plate Dish", &"tray_with_finished_order", 1,
		[{"item": &"tray_with_order", "amount": 1, "needs_order": true},
		 {"item": &"burger", "amount": 1}], &"assembly", 10, &"", &"order_dish")
	_make("deliver", "Hand Over", &"tray_dirty", 1,
		[{"item": &"tray_with_finished_order", "amount": 1, "needs_order": true}],
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
