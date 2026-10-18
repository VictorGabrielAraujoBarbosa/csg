extends Node3D
## Preview for the "dressed" composite props in res://resources/props/.
##
## Instantiates every prop exactly the way the kitchen does (FurnitureDef +
## FurnitureInstance: auto footprint from MeshBounds.combined_aabb, AABB
## centring, scale_mult = 2), drops them on a 1 m checker floor, frames them
## with the game's camera rig (pitch 50, yaw 0) and prints the measured
## footprint of each piece.
##
## Run:
##   DISPLAY=:1 godot --path . res://tools/props_dress_preview.tscn
## Writes to /tmp/opencode: props_dress.png (the props plus the plain kit pieces
## they are built on, one 1 m cell apart), props_dress_close_<id>.png and
## props_dress_back_<id>.png (one shot per piece, from the game camera and from
## behind) and props_dress_far.png (the build-phase camera distance).
##
## Authoring helpers, for hand-placing children in a .tscn:
##   -- --models   native AABB of every candidate kit model, plus a rendered
##                 index image of the same models on the checker floor
##   -- --faces    every axis-aligned surface of the base models (the shelf
##                 boards, the fridge top, the table top), so children can be
##                 placed on real geometry instead of guessed heights

const OUT_PATH := "/tmp/opencode/props_dress.png"
const CLOSE_PATH := "/tmp/opencode/props_dress_close_%s.png"
const BACK_PATH := "/tmp/opencode/props_dress_back_%s.png"
const FAR_PATH := "/tmp/opencode/props_dress_far.png"
const MODEL_INDEX_PATH := "/tmp/opencode/props_dress_model_index.png"
const PROP_DIR := "res://resources/props/"
## Props shown in the near row, in this order, one grid anchor each.
const PROPS: Array[String] = ["shelf_stocked", "fridge_stocked", "table_dressed"]
## Plain kit pieces shown after the props, for scale comparison.
const REFERENCE: Array[String] = ["shelf", "fridge", "table"]
const FIRST_CELL := Vector2i(0, 0)
const FRAMES_BEFORE_SHOT := 30
## Camera framing: the game rig (pitch 50, fov 79).
const ROW_DISTANCE := 6.5
const CLOSE_DISTANCE := 2.6
## The distance the game camera sits at while building (see CameraRig.distance).
const FAR_DISTANCE := 15.0

## Models dumped by the `--models` authoring mode.
const MODELS: Array[String] = [
	"res://assets/kenney_furniture-kit/Models/GLTF format/bookcaseClosed.glb",
	"res://assets/kenney_furniture-kit/Models/GLTF format/kitchenFridge.glb",
	"res://assets/kenney_furniture-kit/Models/GLTF format/kitchenFridgeSmall.glb",
	"res://assets/kenney_furniture-kit/Models/GLTF format/table.glb",
	"res://assets/kenney_furniture-kit/Models/GLTF format/tableRound.glb",
	"res://assets/kenney_furniture-kit/Models/GLTF format/pottedPlant.glb",
	"res://assets/kenney_furniture-kit/Models/GLTF format/plantSmall1.glb",
	"res://assets/kenney_furniture-kit/Models/GLTF format/plantSmall2.glb",
	"res://assets/kenney_furniture-kit/Models/GLTF format/plantSmall3.glb",
	"res://assets/kenney_food-kit/Models/GLB format/bread.glb",
	"res://assets/kenney_food-kit/Models/GLB format/carton.glb",
	"res://assets/kenney_food-kit/Models/GLB format/carton-small.glb",
	"res://assets/kenney_food-kit/Models/GLB format/cheese.glb",
	"res://assets/kenney_food-kit/Models/GLB format/cheese-cut.glb",
	"res://assets/kenney_food-kit/Models/GLB format/broccoli.glb",
	"res://assets/kenney_food-kit/Models/GLB format/carrot.glb",
	"res://assets/kenney_food-kit/Models/GLB format/tomato.glb",
	"res://assets/kenney_food-kit/Models/GLB format/cabbage.glb",
	"res://assets/kenney_food-kit/Models/GLB format/plate.glb",
	"res://assets/kenney_food-kit/Models/GLB format/plate-dinner.glb",
	"res://assets/kenney_food-kit/Models/GLB format/cup.glb",
	"res://assets/kenney_food-kit/Models/GLB format/cup-coffee.glb",
	"res://assets/kenney_food-kit/Models/GLB format/bowl.glb",
	"res://assets/kenney_food-kit/Models/GLB format/shaker-pepper.glb",
	"res://assets/kenney_food-kit/Models/GLB format/bottle-ketchup.glb",
	"res://assets/kenney_food-kit/Models/GLB format/bottle-musterd.glb",
	"res://assets/kenney_food-kit/Models/GLB format/shaker-salt.glb",
	"res://assets/kenney_food-kit/Models/GLB format/croissant.glb",
	"res://assets/kenney_food-kit/Models/GLB format/sausage.glb",
	"res://assets/kenney_food-kit/Models/GLB format/whole-ham.glb",
	"res://assets/kenney_food-kit/Models/GLB format/sandwich.glb",
	"res://assets/kenney_food-kit/Models/GLB format/salad.glb",
	"res://assets/kenney_food-kit/Models/GLB format/apple.glb",
	"res://assets/kenney_food-kit/Models/GLB format/banana.glb",
	"res://assets/kenney_food-kit/Models/GLB format/grapes.glb",
	"res://assets/kenney_food-kit/Models/GLB format/leek.glb",
	"res://assets/kenney_food-kit/Models/GLB format/radish.glb",
	"res://assets/kenney_food-kit/Models/GLB format/onion.glb",
	"res://assets/kenney_food-kit/Models/GLB format/pepper.glb",
	"res://assets/kenney_food-kit/Models/GLB format/egg.glb",
	"res://assets/kenney_food-kit/Models/GLB format/pot.glb",
	"res://assets/kenney_food-kit/Models/GLB format/soda-bottle.glb",
	"res://assets/kenney_food-kit/Models/GLB format/glass.glb",
]

## Models whose up-facing surfaces the `--faces` authoring mode lists.
const FACE_MODELS: Array[String] = [
	"res://assets/kenney_furniture-kit/Models/GLTF format/bookcaseClosed.glb",
	"res://assets/kenney_furniture-kit/Models/GLTF format/kitchenFridge.glb",
	"res://assets/kenney_furniture-kit/Models/GLTF format/table.glb",
]

var _viewport: SubViewport
var _rig: CameraRig
## "id=1x1" lines, printed again as one summary at the end of the run.
var _measured_summary: PackedStringArray = PackedStringArray()


func _ready() -> void:
	_viewport = get_node_or_null("Viewport") as SubViewport
	_rig = get_node_or_null("Viewport/CameraRig") as CameraRig
	if _viewport == null or _rig == null or _rig.camera == null:
		print("[props-dress] FAIL - the preview scene is missing its viewport or camera rig")
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--models"):
		await _dump_models()
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--faces"):
		_dump_faces()
		get_tree().quit()
		return
	_build_floor()
	var row: Array = []
	var cell := FIRST_CELL
	for prop_id: String in PROPS:
		var prop := _prop_def(prop_id)
		if prop == null:
			continue
		_place_def(prop, cell)
		_report(prop, cell)
		row.append([prop, cell])
		cell.x += maxi(prop.resolved_footprint().x, 1)
	# Where the props end and the plain reference pieces begin.
	var prop_end := cell.x
	for ref_id: String in REFERENCE:
		var def := FurnitureCatalog.find(StringName(ref_id))
		if def == null:
			print("[props-dress] FAIL - no catalog def for %s" % ref_id)
			continue
		_place_def(def, cell)
		row.append([def, cell])
		cell.x += maxi(def.resolved_footprint().x, 1)
	var middle := Vector3((cell.x - FIRST_CELL.x) * 0.5, 0.4, 0.0)
	# The props alone, for the build-phase distance check (the plain reference
	# pieces would only push them out of frame).
	var props_center := Vector3((prop_end - FIRST_CELL.x) * 0.5, 0.4, 0.0)
	await _shoot(OUT_PATH, middle, ROW_DISTANCE)
	# One close shot per piece, to spot floating or intersecting children that
	# the row shot is too small to show.
	for entry: Array in row:
		var def: FurnitureDef = entry[0]
		var at: Vector2i = entry[1]
		var aabb := _prop_aabb(def)
		var height := aabb.end.y * def.scale_mult
		var center := Vector2(at) + Vector2(def.cell_center_offset(0)) \
				- Vector2(def.resolved_footprint()) * 0.5 + Vector2(0.5, 0.5)
		# Frame the whole piece: tall props (the fridge) need a higher focus and
		# a longer shot or their top decoration falls out of frame.
		var focus := Vector3(center.x, clampf(height * 0.5, 0.4, 1.15), center.y)
		var distance := maxf(CLOSE_DISTANCE, height * 2.1)
		await _shoot(CLOSE_PATH % def.id, focus, distance)
		# Second angle: pieces whose front faces -Z would look like blank boxes
		# from the game camera, so check the back too.
		await _shoot(BACK_PATH % def.id, focus, distance, 180.0)
	# The build-phase camera distance: do the props still read from up here?
	await _shoot(FAR_PATH, props_center, FAR_DISTANCE)
	print("[props-dress] wrote %s, %s* and %s" % [OUT_PATH, CLOSE_PATH % "<id>", FAR_PATH])
	print("[props-dress] the props alone measure: %s"
		% ", ".join(_measured_summary))
	get_tree().quit()


# ---------------------------------------------------------------------------
# Scene setup
# ---------------------------------------------------------------------------

## 1 m checkered floor tiles with a hair of gap between them, so the cell each
## piece occupies is visible in the screenshot.
func _build_floor() -> void:
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 60.0)
	ground.mesh = plane
	ground.position = Vector3(0.0, -0.06, 0.0)
	ground.material_override = _material(Color(0.22, 0.23, 0.26))
	_viewport.add_child(ground)

	var tile := BoxMesh.new()
	tile.size = Vector3(0.98, 0.1, 0.98)
	var light := _material(Color(0.72, 0.73, 0.76))
	var dark := _material(Color(0.60, 0.62, 0.67))
	var tiles := Node3D.new()
	tiles.name = "Tiles"
	_viewport.add_child(tiles)
	for x in range(-6, 10):
		for z in range(-4, 5):
			var mi := MeshInstance3D.new()
			mi.mesh = tile
			mi.position = Vector3(x, -0.05, z)
			mi.material_override = light if ((x + z) & 1) == 0 else dark
			tiles.add_child(mi)


func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	return mat


func _prop_def(prop_id: String) -> FurnitureDef:
	var path := PROP_DIR + prop_id + ".tscn"
	var packed := load(path) as PackedScene
	if packed == null:
		print("[props-dress] FAIL - could not load %s" % path)
		return null
	var def := FurnitureDef.new()
	def.id = StringName(prop_id)
	def.display_name = prop_id.capitalize()
	def.scene = packed
	def.scale_mult = 2.0
	return def


## Places a furniture def (a prop or a plain kit model) on a cell, offset to the
## centre of its footprint exactly like Kitchen.place_furniture does.
func _place_def(def: FurnitureDef, cell: Vector2i) -> void:
	if def == null:
		print("[props-dress] FAIL - no def for cell %s" % cell)
		return
	var inst := FurnitureInstance.new()
	inst.name = String(def.id)
	inst.setup(def, cell, 0)
	_viewport.add_child(inst)
	var off := def.cell_center_offset(0)
	inst.position = Vector3(cell.x + off.x, 0.0, cell.y + off.y)
	inst.rotation_degrees = Vector3(0.0, def.yaw_offset_deg, 0.0)


# ---------------------------------------------------------------------------
# Measuring / reporting
# ---------------------------------------------------------------------------

## Combined AABB of a prop scene, in the prop's own (native kit) space.
func _prop_aabb(def: FurnitureDef) -> AABB:
	if def == null or def.scene == null:
		return AABB()
	var node := def.scene.instantiate() as Node3D
	if node == null:
		return AABB()
	var aabb := MeshBounds.combined_aabb(node)
	node.free()
	return aabb


## Prints the numbers FurnitureDef._measure() works from, so the claimed
## footprint can be checked against the model that is actually rendered.
func _report(def: FurnitureDef, cell: Vector2i) -> void:
	var node := def.scene.instantiate() as Node3D
	if node == null:
		print("[props-dress] FAIL - %s is not a Node3D" % def.id)
		return
	var aabb := MeshBounds.combined_aabb(node)
	var footprint := def.resolved_footprint()
	var meshes := 0
	var materials := PackedStringArray()
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			meshes += 1
			var mi := n as MeshInstance3D
			if mi.mesh != null:
				for i in mi.mesh.get_surface_count():
					var mat := mi.mesh.surface_get_material(i)
					if mat != null and not mat.resource_name.is_empty() \
							and not materials.has(mat.resource_name):
						materials.append(mat.resource_name)
		for child in n.get_children():
			stack.append(child)
	node.free()
	var world := aabb.size * def.scale_mult * def.scale_axis
	print("[prop] %-16s cell=%s aabb=(%.3f, %.3f, %.3f) native  world=(%.3f, %.3f, %.3f) m"
		% [def.id, cell, aabb.size.x, aabb.size.y, aabb.size.z, world.x, world.y, world.z])
	print("[prop] %-16s footprint=%s cells  top(surface_y)=%.3f m  meshes=%d  materials=%s"
		% [def.id, str(footprint), aabb.end.y * def.scale_mult, meshes, ", ".join(materials)])
	print("[prop] %s - %s measures %s cells and sits on the floor (min y %.3f)"
		% ["ok" if is_zero_approx(aabb.position.y) else "INFO",
			def.id, str(footprint), aabb.position.y])
	_measured_summary.append("%s=%s cells (top %.2f m)"
		% [def.id, str(footprint), aabb.end.y * def.scale_mult])


## Authoring helper: up-facing horizontal surfaces of the given models, so a
## composition can be placed on real shelf boards instead of guessed heights.
func _dump_faces() -> void:
	for path: String in FACE_MODELS:
		var packed := load(path) as PackedScene
		if packed == null:
			print("[faces] FAIL - could not load %s" % path)
			continue
		var node := packed.instantiate() as Node3D
		if node == null:
			print("[faces] FAIL - %s is not a Node3D" % path)
			continue
		print("[faces] %s" % path.get_file())
		var stack: Array = [[node, node.transform]]
		while not stack.is_empty():
			var item: Array = stack.pop_back()
			var n: Node = item[0]
			var xf: Transform3D = item[1]
			if n is MeshInstance3D:
				_dump_mesh_faces((n as MeshInstance3D), xf)
			for child in n.get_children():
				var child_xf := xf
				if child is Node3D:
					child_xf = xf * (child as Node3D).transform
				stack.append([child, child_xf])
		node.free()


## Groups one mesh's axis-aligned triangles by plane and prints each group's
## footprint, biggest first: a shelf board shows up as one flat slab, a door as
## one big panel on the +Z or -Z plane.
func _dump_mesh_faces(mi: MeshInstance3D, xf: Transform3D) -> void:
	if mi.mesh == null:
		return
	var arrays := mi.mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var tri_count := indices.size() / 3 if indices.size() > 0 else verts.size() / 3
	var groups: Dictionary = {"up": {}, "down": {}, "front": {}, "back": {}, "left": {}, "right": {}}
	for t in tri_count:
		var i0 := indices[t * 3] if indices.size() > 0 else t * 3
		var i1 := indices[t * 3 + 1] if indices.size() > 0 else t * 3 + 1
		var i2 := indices[t * 3 + 2] if indices.size() > 0 else t * 3 + 2
		var a := xf * verts[i0]
		var b := xf * verts[i1]
		var c := xf * verts[i2]
		var normal := (b - a).cross(c - a)
		if normal.length_squared() < 0.000001:
			continue
		normal = normal.normalized()
		var group := ""
		var key := 0.0
		if absf(normal.y) > 0.9:
			group = "up" if normal.y > 0.0 else "down"
			key = snappedf((a.y + b.y + c.y) / 3.0, 0.001)
		elif absf(normal.z) > 0.9:
			group = "front" if normal.z > 0.0 else "back"
			key = snappedf((a.z + b.z + c.z) / 3.0, 0.001)
		elif absf(normal.x) > 0.9:
			group = "right" if normal.x > 0.0 else "left"
			key = snappedf((a.x + b.x + c.x) / 3.0, 0.001)
		else:
			continue
		var bands: Dictionary = groups[group]
		var box: AABB = bands.get(key, AABB(a, Vector3.ZERO))
		box = box.expand(a).expand(b).expand(c)
		bands[key] = box
	for group: String in ["up", "down", "front", "back", "left", "right"]:
		var bands: Dictionary = groups[group]
		var keys := bands.keys()
		keys.sort()
		for key: float in keys:
			var box: AABB = bands[key]
			print("[faces]   %-5s at %6.3f  x=[%6.3f,%6.3f]  y=[%6.3f,%6.3f]  z=[%6.3f,%6.3f]  area=%5.3f"
				% [group, key, box.position.x, box.end.x, box.position.y, box.end.y,
					box.position.z, box.end.z, box.size.x * box.size.z])


## Authoring helper: native AABB of every candidate kit model.
func _dump_models() -> void:
	for path: String in MODELS:
		var packed := load(path) as PackedScene
		if packed == null:
			print("[models] FAIL - could not load %s" % path)
			continue
		var node := packed.instantiate() as Node3D
		if node == null:
			print("[models] FAIL - %s is not a Node3D" % path)
			continue
		var aabb := MeshBounds.combined_aabb(node)
		print("[models] %-22s min=(%7.3f,%7.3f,%7.3f) size=(%6.3f,%6.3f,%6.3f) max_y=%6.3f"
			% [path.get_file(), aabb.position.x, aabb.position.y, aabb.position.z,
				aabb.size.x, aabb.size.y, aabb.size.z, aabb.end.y])
		node.free()
	# Second pass: the same models in a grid on the checker floor, at native
	# scale, so the picture matches the printed numbers.
	_build_floor()
	var index := 0
	var placed := 0
	for path: String in MODELS:
		var packed := load(path) as PackedScene
		if packed == null:
			continue
		var node := packed.instantiate() as Node3D
		if node == null:
			continue
		var aabb := MeshBounds.combined_aabb(node)
		var cell := Vector2i(index % 8, index / 8)
		node.position = Vector3(cell.x * 1.2 - aabb.get_center().x,
			0.0, cell.y * 1.2 - aabb.get_center().z)
		_viewport.add_child(node)
		index += 1
	placed = index
	var rows := float(maxi(placed, 1)) / 8.0
	await _shoot(MODEL_INDEX_PATH, Vector3(4.2, 0.4, (rows - 1.0) * 0.6), 15.0)


# ---------------------------------------------------------------------------
# Camera + screenshot
# ---------------------------------------------------------------------------

## Moves the rig to a fixed framing, waits for the frame, saves a PNG.
func _shoot(path: String, focus: Vector3, distance: float, yaw := 0.0) -> void:
	_rig.pitch_deg = 50.0
	_rig._yaw_deg = yaw
	_rig._distance = distance
	_rig._target_distance = distance
	_rig._focus = focus
	_rig._target_focus = focus
	_rig._apply()
	for i in FRAMES_BEFORE_SHOT:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := _viewport.get_texture().get_image()
	var err := image.save_png(path)
	print("[props-dress] screenshot %s (err=%d, %dx%d)"
		% [path, err, image.get_width(), image.get_height()])
