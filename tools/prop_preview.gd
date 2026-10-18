extends Node3D
## Standalone preview for the composite prop scenes in res://resources/props/.
##
## Instantiates every prop exactly the way the kitchen does (FurnitureDef +
## FurnitureInstance: auto footprint from MeshBounds.combined_aabb, AABB
## centring, scale_mult = 2), drops them one 1 m grid cell apart on a checkered
## floor, frames them with the game's camera rig (pitch 50, yaw 0) and prints
## the measured footprint of each piece.
##
## Run:
##   DISPLAY=:1 godot --path . res://tools/prop_preview.tscn
## Writes three shots into /tmp/opencode: props_preview.png (the row, preview
## distance), props_preview_close.png (the first prop up close) and
## props_preview_far.png (the row from the build-phase camera distance).

const OUT_PATH := "/tmp/opencode/props_preview.png"
const CLOSE_PATH := "/tmp/opencode/props_preview_close.png"
const FAR_PATH := "/tmp/opencode/props_preview_far.png"
const PROP_DIR := "res://resources/props/"
## Props shown in the near row, one per 1 m cell (left to right).
const PROPS: Array[String] = ["cutting_table", "plating_station"]
## Plain kit pieces shown to the right of the props, for scale comparison.
const REFERENCE: Array[String] = ["counter"]
const FIRST_CELL := Vector2i(0, 0)
const FRAMES_BEFORE_SHOT := 30
## Camera framing: the game rig (pitch 50, fov 79) at a preview distance.
const ROW_DISTANCE := 4.2
const CLOSE_DISTANCE := 2.4
## The distance the game camera sits at while building (see CameraRig.distance).
const FAR_DISTANCE := 15.0

var _viewport: SubViewport
var _rig: CameraRig


func _ready() -> void:
	_viewport = get_node_or_null("Viewport") as SubViewport
	_rig = get_node_or_null("Viewport/CameraRig") as CameraRig
	if _viewport == null or _rig == null or _rig.camera == null:
		print("[prop-preview] FAIL - the preview scene is missing its viewport or camera rig")
		get_tree().quit()
		return
	_build_floor()
	var cell := FIRST_CELL
	for prop_id: String in PROPS:
		_place_prop(prop_id, cell)
		cell.x += 1
	for ref_id: String in REFERENCE:
		_place_def(FurnitureCatalog.find(StringName(ref_id)), cell)
		cell.x += 1
	await _shoot(OUT_PATH, Vector3(1.0, 0.45, 0.0), ROW_DISTANCE)
	# Second pass: the first prop alone, close up, to spot floating or
	# intersecting children that the row shot is too small to show.
	await _shoot(CLOSE_PATH, Vector3(0.1, 0.55, -0.15), CLOSE_DISTANCE)
	# Third pass: the build-phase camera distance, to check the props still read
	# as stations (and not as plain counters) from where the player looks.
	await _shoot(FAR_PATH, Vector3(1.0, 0.45, 0.0), FAR_DISTANCE)
	print("[prop-preview] wrote %s, %s and %s" % [OUT_PATH, CLOSE_PATH, FAR_PATH])
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
	var light := _material(Color(0.88, 0.89, 0.92))
	var dark := _material(Color(0.78, 0.80, 0.85))
	var tiles := Node3D.new()
	tiles.name = "Tiles"
	_viewport.add_child(tiles)
	for x in range(-6, 8):
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


## Places one composite prop scene through the real furniture pipeline.
func _place_prop(prop_id: String, cell: Vector2i) -> void:
	var path := PROP_DIR + prop_id + ".tscn"
	var packed := load(path) as PackedScene
	if packed == null:
		print("[prop-preview] FAIL - could not load %s" % path)
		return
	var def := FurnitureDef.new()
	def.id = StringName(prop_id)
	def.display_name = prop_id.capitalize()
	def.scene = packed
	def.scale_mult = 2.0
	_place_def(def, cell)
	_report(def, cell)


## Places a furniture def (a prop or a plain kit model) on a cell.
func _place_def(def: FurnitureDef, cell: Vector2i) -> void:
	if def == null:
		print("[prop-preview] FAIL - no def for cell %s" % cell)
		return
	var inst := FurnitureInstance.new()
	inst.name = String(def.id)
	inst.setup(def, cell, 0)
	_viewport.add_child(inst)
	inst.position = Vector3(cell.x, 0.0, cell.y)
	inst.rotation_degrees = Vector3(0.0, def.yaw_offset_deg, 0.0)


# ---------------------------------------------------------------------------
# Measuring / reporting
# ---------------------------------------------------------------------------

## Prints the numbers FurnitureDef._measure() works from, so the claimed
## footprint can be checked against the model that is actually rendered.
func _report(def: FurnitureDef, cell: Vector2i) -> void:
	var node := def.scene.instantiate() as Node3D
	if node == null:
		print("[prop-preview] FAIL - %s is not a Node3D" % def.id)
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
		% ["ok" if footprint == Vector2i.ONE and is_zero_approx(aabb.position.y) else "INFO",
			def.id, str(footprint), aabb.position.y])


# ---------------------------------------------------------------------------
# Camera + screenshot
# ---------------------------------------------------------------------------

## Moves the rig to a fixed framing, waits for the frame, saves a PNG.
func _shoot(path: String, focus: Vector3, distance: float) -> void:
	_rig.pitch_deg = 50.0
	_rig._yaw_deg = 0.0
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
	print("[prop-preview] screenshot %s (err=%d, %dx%d)" % [path, err, image.get_width(), image.get_height()])
