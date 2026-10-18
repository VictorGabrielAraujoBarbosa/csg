class_name ItemCatalog
## Every item that can exist in the world. Food models come from Kenney's food
## kit (scale ~0.3 to match our 1 m world), trays are re-used tableware.

const FOOD_DIR := "res://assets/kenney_food-kit/Models/GLB format/"
const FOOD_PREVIEWS := "res://assets/kenney_food-kit/Previews/"
## Cartoon-big food so it reads clearly from the game camera (the kit is
## modelled at ~3.3 units/m, so 0.7 gives a ~28 cm burger).
const FOOD_SCALE := 0.7
const TRAY_SCALE := 0.32

static var _cache: Dictionary = {}
static var _by_id: Dictionary = {}


static func all() -> Dictionary:
	if _cache.is_empty():
		_build()
	return _cache


static func find(id: StringName) -> ItemDef:
	all()
	return _by_id.get(id)


## Releases the cached resources (called on shutdown so the engine exits clean).
static func clear_caches() -> void:
	_cache.clear()
	_by_id.clear()


## Items that fill the world at start (the tray pool).
static func tray_ids() -> Array[StringName]:
	return [&"tray", &"tray_with_order", &"tray_with_finished_order", &"tray_dirty"]


static func _build() -> void:
	_cache.clear()
	_by_id.clear()
	# Base ingredients (infinite from storage in this version).
	_add("bread", "Bread", "bread.glb", true)
	_add("patty_raw", "Raw Patty", "meat-patty.glb", true)
	_add("lettuce", "Lettuce", "cabbage.glb", true)
	_add("tomato", "Tomato", "tomato.glb", true, &"", {"scale": 1.2})
	_add("cheese", "Cheese", "cheese.glb", true)
	# No potato in the kit: the coconut is the one plain brown lump (at the
	# standard food scale it renders ~18 cm, next to a portion of fries).
	_add("potato", "Potato", "coconut.glb", true)
	_add("sauce", "Sauce", "soy.glb", true)
	# Made ingredients.
	_add("fries", "Fries", "fries.glb", false)
	_add("patty_cooked", "Cooked Patty", "meat-cooked.glb", false)
	_add("cheese_slice", "Cheese Slice", "cheese-cut.glb", false)
	_add("salad", "Salad", "salad.glb", false)
	_add("burger", "Burger", "burger.glb", false)
	# Trays (a small reusable pool).
	_add("tray", "Tray", "plate-rectangle.glb", false, &"tray", {"scale": TRAY_SCALE})
	_add("tray_with_order", "Tray + Order", "plate-rectangle.glb", false, &"tray", {
		"scale": TRAY_SCALE,
		"extra": "styrofoam.glb",
		"extra_scale": 0.12,
		"extra_offset": Vector3(-0.05, 0.0, 0.03),
	})
	_add("tray_with_finished_order", "Tray + Dish", "plate-rectangle.glb", false, &"tray", {
		"scale": TRAY_SCALE,
		"extra_from_payload": &"dish",
		"extra_offset": Vector3(0.0, 0.02, 0.0),
	})
	_add("tray_dirty", "Dirty Tray", "plate-rectangle.glb", false, &"tray", {
		"scale": TRAY_SCALE,
		"tint": Color(0.72, 0.7, 0.62),
	})


static func _add(id: String, name: String, file: String, is_base: bool, tag := &"", extra := {}) -> void:
	var def := ItemDef.new()
	def.id = StringName(id)
	def.display_name = name
	def.scene = load(FOOD_DIR + file) as PackedScene
	def.preview_path = FOOD_PREVIEWS + file.get_basename() + ".png"
	def.scale_mult = extra.get("scale", FOOD_SCALE)
	def.is_base = is_base
	def.tag = tag
	if extra.has("extra"):
		def.extra_scene = load(FOOD_DIR + str(extra["extra"])) as PackedScene
	if extra.has("extra_scale"):
		def.extra_scale = extra["extra_scale"]
	if extra.has("extra_offset"):
		def.extra_offset = extra["extra_offset"]
	if extra.has("extra_from_payload"):
		def.extra_from_payload = extra["extra_from_payload"]
	if extra.has("tint"):
		def.tint = extra["tint"]
	_cache[def.id] = def
	_by_id[def.id] = def
