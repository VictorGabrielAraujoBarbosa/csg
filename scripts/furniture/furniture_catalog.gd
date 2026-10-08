class_name FurnitureCatalog
## Everything the player can buy and place. These will become .tres resources
## (editable in the inspector) once the shop needs balancing; for now keeping
## them in one script is the fastest thing to edit.

const FURNITURE_DIR := "res://assets/kenney_furniture-kit/Models/GLTF format/"

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


static func build() -> Array[FurnitureDef]:
	var out: Array[FurnitureDef] = []
	# id, name, model, footprint, cost, tags
	out.append(_make("stove", "Stove", "kitchenStove.glb", Vector2i(1, 1), 120, ["cooking", "heat"]))
	out.append(_make("sink", "Sink", "kitchenSink.glb", Vector2i(1, 1), 100, ["washing", "water"]))
	out.append(_make("fridge", "Fridge", "kitchenFridge.glb", Vector2i(1, 1), 150, ["storage", "cold"]))
	out.append(_make("counter", "Counter", "kitchenCabinet.glb", Vector2i(1, 1), 60, ["prep", "surface"]))
	out.append(_make("drawer_counter", "Drawer Counter", "kitchenCabinetDrawer.glb", Vector2i(1, 1), 80, ["prep", "surface", "storage"]))
	out.append(_make("bar", "Serving Bar", "kitchenBar.glb", Vector2i(1, 1), 90, ["serving", "surface"]))
	out.append(_make("bar_end", "Bar End", "kitchenBarEnd.glb", Vector2i(1, 1), 50, ["serving"]))
	out.append(_make("trash", "Trash Can", "trashcan.glb", Vector2i(1, 1), 30, ["bin"]))
	out.append(_make("shelf", "Shelf", "bookcaseClosed.glb", Vector2i(1, 1), 70, ["storage"]))
	out.append(_make("table", "Table", "table.glb", Vector2i(2, 1), 70, ["dining", "surface"]))
	out.append(_make("table_round", "Round Table", "tableRound.glb", Vector2i(2, 2), 90, ["dining", "surface"]))
	out.append(_make("table_cross", "Banquet Table", "tableCross.glb", Vector2i(5, 3), 200, ["dining", "surface"]))
	out.append(_make("side_table", "Side Table", "sideTable.glb", Vector2i(2, 1), 50, ["prep", "surface"]))
	out.append(_make("chair", "Chair", "chair.glb", Vector2i(1, 1), 25, ["dining"]))
	out.append(_make("bench", "Bench", "bench.glb", Vector2i(1, 1), 30, ["dining"]))
	out.append(_make("sofa", "Sofa", "loungeSofa.glb", Vector2i(2, 1), 110, ["dining", "comfort"]))
	out.append(_make("sofa_long", "Long Sofa", "loungeDesignSofa.glb", Vector2i(3, 1), 160, ["dining", "comfort"]))
	out.append(_make("desk", "Desk", "desk.glb", Vector2i(2, 2), 100, ["desk", "surface"]))
	out.append(_make("fridge_large", "Large Fridge", "kitchenFridgeLarge.glb", Vector2i(2, 1), 220, ["storage", "cold"]))
	out.append(_make("assembly_table", "Assembly Table", "table.glb", Vector2i(3, 1), 140, ["assembly"]))
	out.append(_make("worker_post", "Worker Post", "rugDoormat.glb", Vector2i(1, 1), 0, ["worker"]))
	out.append(_make("plant", "Plant", "plantSmall1.glb", Vector2i(1, 1), 15, ["decor"]))
	return out


static func _make(id: String, name: String, file: String, footprint: Vector2i, cost: int, tags: Array) -> FurnitureDef:
	var def := FurnitureDef.new()
	def.id = StringName(id)
	def.display_name = name
	def.scene = load(FURNITURE_DIR + file) as PackedScene
	def.footprint = footprint
	def.cost = cost
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
