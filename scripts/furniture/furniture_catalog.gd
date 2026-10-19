class_name FurnitureCatalog
## Everything the player can buy and place. These will become .tres resources
## (editable in the inspector) once the shop needs balancing; for now keeping
## them in one script is the fastest thing to edit.

const FURNITURE_DIR := "res://assets/kenney_furniture-kit/Models/GLTF format/"
const ISOMETRIC_DIR := "res://assets/kenney_furniture-kit/Isometric/"
const PROPS_DIR := "res://resources/props/"

static var _cache: Array[FurnitureDef] = []


## The full catalog (built once).
static func all() -> Array[FurnitureDef]:
	if _cache.is_empty():
		_cache = build()
	return _cache


static func find(id: StringName) -> FurnitureDef:
	for def in all():
		if def.id == id:
			return def
	return null


## Releases the cached resources (called on shutdown so the engine exits clean).
static func clear_caches() -> void:
	_cache.clear()


## Only the pieces on sale in the build phase, in catalog order.
static func shop_items() -> Array[FurnitureDef]:
	var out: Array[FurnitureDef] = []
	for def in all():
		if def.shop:
			out.append(def)
	return out


## The shop pieces with a production role (everything but decoration). This is
## what the All tab shows: decoration is a money sink, not a job, and it would
## only add noise to the default view — it lives in its own tab.
static func production_items() -> Array[FurnitureDef]:
	var out: Array[FurnitureDef] = []
	for def in all():
		if def.shop and def.category != &"decor":
			out.append(def)
	return out


## The shop groupings that actually have something in them, in a fixed order:
## what holds ingredients, what runs recipes, who does the work, and what is
## decoration (the only tab a piece with no production role may sit in).
static func shop_categories() -> Array[StringName]:
	var order: Array[StringName] = [&"storage", &"workstations", &"workers", &"decor"]
	var out: Array[StringName] = []
	for category in order:
		for def in all():
			if def.shop and def.category == category:
				out.append(category)
				break
	return out


static func category_label(category: StringName) -> String:
	match category:
		&"workstations":
			return "Workstations"
		&"storage":
			return "Storage"
		&"workers":
			return "Workers"
		&"decor":
			return "Decoration"
	return String(category)


static func build() -> Array[FurnitureDef]:
	var out: Array[FurnitureDef] = []
	# id, name, model, footprint, cost, tags, category, shop
	# --- the shop: everything that has a job in the kitchen ---
	out.append(_make("stove", "Stove", "kitchenStove.glb", Vector2i(1, 1), 120, ["cooking", "heat"], &"workstations", true,
		"Cooks raw patties. Burgers cannot be made without one."))
	out.append(_make("sink", "Sink", "kitchenSink.glb", Vector2i(1, 1), 100, ["washing", "water"], &"workstations", true,
		"Washes dirty trays. Without one, trays run out and orders stop."))
	out.append(_make("fryer", "Fryer", "kitchenMicrowave.glb", Vector2i(1, 1), 120, ["frying"], &"workstations", true,
		"Fries potatoes. Orders with + fries cannot be made without one."))
	out.append(_make("assembly_table", "Assembly Table", "table.glb", Vector2i(3, 1), 140, ["assembly"], &"workstations", true,
		"Assembles finished dishes. The last step before plating."))
	out.append(_make("counter", "Counter", "kitchenCabinet.glb", Vector2i(1, 1), 60, ["surface"], &"decor", true,
		"DECORATION — somewhere to put things down. No recipes run here."))
	# Storage: base ingredients are taken from a `storage` station, so a kitchen
	# with none of these cannot cook at all. The plain kit shelf and fridge are
	# the redundant sizes (the authored maps use them): the shop sells the
	# stocked props, so they stay in the catalog but off the shelves.
	out.append(_make("shelf", "Shelf", "bookcaseClosed.glb", Vector2i(1, 1), 70, ["storage"], &"storage", false,
		"Dry storage: bread, potatoes and sauce come from here."))
	out.append(_make("fridge", "Fridge", "kitchenFridge.glb", Vector2i(1, 1), 150, ["cold"], &"storage", false,
		"Cold storage: raw patties, cheese, tomatoes and lettuce come from here."))
	# Composed props: several kit models in one scene, measured like any piece.
	out.append(_make_prop("cutting_table", "Cutting Table", "cutting_table.tscn", Vector2i(1, 1), 90,
		["prep", "surface"], 0.9, "Prep surface: salads and cheese slices are made here."))
	out.append(_make_prop("plating_station", "Plating Station", "plating_station.tscn", Vector2i(1, 1), 110,
		["prep", "surface"], 0.9,
		"Prep surface: salads and cheese slices are made here. Same job as the Cutting Table."))
	out.append(_make("worker_post", "Worker Post", "rugDoormat.glb", Vector2i(1, 1), 60, ["worker"], &"workers", true,
		"Adds one worker. More posts, more orders served at once."))
	# --- the rest of the production pieces: buyable in their own tab ---
	# The drawer counter is storage with a worktop: it fetches the dry goods and
	# can still prep on top, so it sits with the storage.
	out.append(_make("drawer_counter", "Drawer Counter", "kitchenCabinetDrawer.glb", Vector2i(1, 1), 80,
		["prep", "surface", "storage"], &"storage", true,
		"Dry storage with a worktop: bread, potatoes and sauce come from here; salads and cheese slices are made on top."))
	out.append(_make("side_table", "Side Table", "sideTable.glb", Vector2i(2, 1), 50, ["prep", "surface"],
		&"workstations", true,
		"Prep surface: salads and cheese slices are made here. Same job as the Cutting Table."))
	out.append(_make("fridge_large", "Large Fridge", "kitchenFridgeLarge.glb", Vector2i(2, 1), 220,
		["storage", "cold"], &"storage", true,
		"Cold and dry storage in one: every ingredient comes from here."))
	# --- decoration: no recipe runs on these and they provide nothing ---
	# Every decoration card is marked in capitals, so nobody buys a plant
	# expecting it to cook. They are a money sink, not a job.
	out.append(_make("bar", "Serving Bar", "kitchenBar.glb", Vector2i(1, 1), 90, ["serving", "surface"], &"decor", true,
		"DECORATION — a serving bar. No recipes run here."))
	out.append(_make("bar_end", "Bar End", "kitchenBarEnd.glb", Vector2i(1, 1), 50, ["serving"], &"decor", true,
		"DECORATION — the end piece of a serving bar. No recipes run here."))
	out.append(_make("trash", "Trash Can", "trashcan.glb", Vector2i(1, 1), 30, ["bin"], &"decor", true,
		"DECORATION — a bin. No recipes run here."))
	out.append(_make("table", "Table", "table.glb", Vector2i(2, 1), 70, ["dining", "surface"], &"decor", true,
		"DECORATION — a dining table. No gameplay effect."))
	out.append(_make("table_round", "Round Table", "tableRound.glb", Vector2i(2, 2), 90, ["dining", "surface"], &"decor", true,
		"DECORATION — a round dining table. No gameplay effect."))
	out.append(_make("table_cross", "Banquet Table", "tableCross.glb", Vector2i(5, 3), 200, ["dining", "surface"], &"decor", true,
		"DECORATION — a long banquet table. No gameplay effect."))
	out.append(_make("chair", "Chair", "chair.glb", Vector2i(1, 1), 25, ["dining"], &"decor", true,
		"DECORATION — a chair. No gameplay effect."))
	out.append(_make("bench", "Bench", "bench.glb", Vector2i(1, 1), 30, ["dining"], &"decor", true,
		"DECORATION — a bench. No gameplay effect."))
	out.append(_make("sofa", "Sofa", "loungeSofa.glb", Vector2i(2, 1), 110, ["dining", "comfort"], &"decor", true,
		"DECORATION — a sofa. No gameplay effect."))
	out.append(_make("sofa_long", "Long Sofa", "loungeDesignSofa.glb", Vector2i(3, 1), 160, ["dining", "comfort"], &"decor", true,
		"DECORATION — a long sofa. No gameplay effect."))
	out.append(_make("desk", "Desk", "desk.glb", Vector2i(2, 2), 100, ["desk", "surface"], &"decor", true,
		"DECORATION — a desk. No gameplay effect."))
	out.append(_make("plant", "Plant", "plantSmall1.glb", Vector2i(1, 1), 15, ["decor"], &"decor", true,
		"DECORATION — no gameplay effect."))
	# The two delivery platforms, recognised only by their colours. Never named,
	# never sold: they simply stand in the restaurant.
	var mascot_red := _make("mascot_red", "Red Mascot", "mascot_red.tscn", Vector2i(1, 1), 0,
		["decor"], &"decor", false, "DECORATION — a delivery platform on display. No gameplay effect.", PROPS_DIR)
	mascot_red.icon_path = ISOMETRIC_DIR + "toilet_NE.png"
	out.append(mascot_red)
	var mascot_yellow := _make("mascot_yellow", "Yellow Mascot", "mascot_yellow.tscn", Vector2i(1, 1), 0,
		["decor"], &"decor", false, "DECORATION — a delivery platform on display. No gameplay effect.", PROPS_DIR)
	mascot_yellow.icon_path = ISOMETRIC_DIR + "toilet_NE.png"
	out.append(mascot_yellow)
	# The two platforms on display together, behind a rail: unmistakably decor,
	# and (like every decoration piece) buyable in the Decoration tab.
	var shrine := _make("corporate_shrine", "Corporate Shrine", "corporate_shrine.tscn", Vector2i(2, 1), 0,
		["decor"], &"decor", true, "DECORATION — the two delivery platforms on display. No gameplay effect.", PROPS_DIR)
	shrine.icon_path = ISOMETRIC_DIR + "toilet_NE.png"
	out.append(shrine)
	# Stocked versions of the storage pieces: the goods are part of the prop, so
	# they read at a glance as "this is where ingredients come from".
	var stocked_shelf := _make("shelf_stocked", "Shelf", "shelf_stocked.tscn", Vector2i(1, 1), 70,
		["storage"], &"storage", true, "Dry storage: bread, potatoes and sauce come from here.", PROPS_DIR)
	stocked_shelf.surface_override = 1.70
	stocked_shelf.icon_path = ISOMETRIC_DIR + "bookcaseClosed_NE.png"
	out.append(stocked_shelf)
	var stocked_fridge := _make("fridge_stocked", "Fridge", "fridge_stocked.tscn", Vector2i(1, 1), 150,
		["cold"], &"storage", true,
		"Cold storage: raw patties, cheese, tomatoes and lettuce come from here. A Shelf does not cover these.", PROPS_DIR)
	stocked_fridge.surface_override = 1.84
	stocked_fridge.icon_path = ISOMETRIC_DIR + "kitchenFridge_NE.png"
	out.append(stocked_fridge)
	var dressed := _make("table_dressed", "Dressed Table", "table_dressed.tscn", Vector2i(2, 1), 90,
		["dining", "surface"], &"decor", true, "DECORATION — a laid table. No gameplay effect.", PROPS_DIR)
	dressed.surface_override = 0.65
	dressed.icon_path = ISOMETRIC_DIR + "table_NE.png"
	out.append(dressed)
	return out


## A composed prop scene (several kit models in one piece): measured and priced
## like any other piece, but its icon has no kit render yet.
static func _make_prop(id: String, name: String, file: String, footprint: Vector2i, cost: int,
		tags: Array, surface: float, desc := "") -> FurnitureDef:
	var def := _make(id, name, file, footprint, cost, tags, &"workstations", true, desc, PROPS_DIR)
	def.icon_path = ISOMETRIC_DIR + "kitchenCabinet_NE.png"  # the props are built on a cabinet
	def.surface_override = surface
	return def


static func _make(id: String, name: String, file: String, footprint: Vector2i, cost: int, tags: Array,
		category: StringName = &"decor", shop := false, desc := "", dir := FURNITURE_DIR) -> FurnitureDef:
	var def := FurnitureDef.new()
	def.id = StringName(id)
	def.display_name = name
	def.scene = load(dir + file) as PackedScene
	def.icon_path = ISOMETRIC_DIR + file.get_basename() + "_NE.png"
	def.footprint = footprint
	def.cost = cost
	def.category = category
	def.shop = shop
	def.description = desc
	var tag_list: Array[StringName] = []
	for tag in tags:
		tag_list.append(StringName(tag))
	def.tags = tag_list
	if id == "assembly_table":
		# A 3x1 station: input cell, worker cell, output cell, left to right.
		def.auto_footprint = false
		def.scale_axis = Vector3(1.55, 1.0, 1.0)
		def.zones = [
			{"offset": Vector2i(0, 0), "role": "input"},
			{"offset": Vector2i(1, 0), "role": "work"},
			{"offset": Vector2i(2, 0), "role": "output"},
		]
	if id == "worker_post":
		# A walkable 1x1 mat: placing it spawns a chibi who idles here.
		def.auto_footprint = false
		def.footprint = Vector2i.ONE
		def.solid = false
	return def
