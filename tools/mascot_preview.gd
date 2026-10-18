extends Node3D
## Standalone preview for the two mascot props (resources/props/mascot_*.tscn).
##
## Instantiates every prop exactly the way the kitchen does (FurnitureDef +
## FurnitureInstance: auto footprint from MeshBounds.combined_aabb, AABB
## centring, scale_mult = 2), drops them on a 1 m checkered floor, frames them
## with the game's camera rig (pitch 50) and prints the measured footprint, the
## authored material colours and a census of the rendered pixels.
##
## Run:
##   DISPLAY=:1 godot --path . res://tools/mascot_preview.tscn
## Writes into /tmp/opencode: mascot_preview.png (the row, game yaw 0),
## mascot_preview_diag.png (yaw 45), mascot_preview_close.png (the red one),
## mascot_preview_far.png (build-phase distance), mascot_census.png (props alone
## on a dark backdrop, the shot the pixel census counts) and mascot_ingame.png
## (both props placed through the real Kitchen.place_furniture, which is where a
## scene-authored paint has to survive the kitchen's tint pass).
##
##   DISPLAY=:1 godot --path . res://tools/mascot_preview.tscn -- --probe
## renders the bare toilet.glb alone (game pitch, then near-top), to check which
## surfaces the player actually looks at and where the hat can stand.
##
##   DISPLAY=:1 godot --path . res://tools/mascot_preview.tscn -- --overlaytest
##   DISPLAY=:1 godot --path . res://tools/mascot_preview.tscn -- --overlayglb
## are the two halves of the paint-mechanism check behind the mascot scenes:
## material_overlay renders on an ordinary mesh but not on this GLB's ArrayMesh,
## so the only paint slot the kitchen cannot clear is the mesh's own material.

const OUT_PATH := "/tmp/opencode/mascot_preview.png"
const DIAG_PATH := "/tmp/opencode/mascot_preview_diag.png"
const CLOSE_PATH := "/tmp/opencode/mascot_preview_close.png"
const FAR_PATH := "/tmp/opencode/mascot_preview_far.png"
const CENSUS_PATH := "/tmp/opencode/mascot_census.png"
const INGAME_PATH := "/tmp/opencode/mascot_ingame.png"
const PROBE_PATH := "/tmp/opencode/mascot_probe.png"
const TOP_PATH := "/tmp/opencode/mascot_probe_top.png"
const OVERLAY_PATH := "/tmp/opencode/mascot_overlay_test.png"

const PROP_DIR := "res://resources/props/"
const TOILET := "res://assets/kenney_furniture-kit/Models/GLTF format/toilet.glb"

## Props shown in the row, one per 1 m cell (left to right).
const PROPS: Array[String] = ["mascot_red", "mascot_yellow"]
const FIRST_CELL := Vector2i(0, 0)
## A bare toilet two cells further right, to compare the paint against.
const REFERENCE_CELL := Vector2i(3, 0)
## Main and sub colours each prop is expected to author, keyed by prop id.
const EXPECTED := {
	"mascot_red": [Color("ea1d2c"), Color("ffffff")],
	"mascot_yellow": [Color("ffd200"), Color("101010")],
}

const FRAMES_BEFORE_SHOT := 30
const ROW_DISTANCE := 4.6
const CLOSE_DISTANCE := 2.3
const FAR_DISTANCE := 15.0
## Mid-gray census backdrop: far enough from white and black that the sub
## colours of both mascots still count as their own family.
const CENSUS_BACKDROP := Color(0.26, 0.3, 0.38)

var _viewport: SubViewport
var _rig: CameraRig
var _tiles: Node3D
var _ground: MeshInstance3D


func _ready() -> void:
	_viewport = get_node_or_null("Viewport") as SubViewport
	_rig = get_node_or_null("Viewport/CameraRig") as CameraRig
	if _viewport == null or _rig == null or _rig.camera == null:
		print("[mascot] FAIL - the preview scene is missing its viewport or camera rig")
		get_tree().quit()
		return
	_build_floor()
	if OS.get_cmdline_user_args().has("--probe"):
		await _run_probe()
	elif OS.get_cmdline_user_args().has("--overlaytest"):
		await _run_overlay_test()
	elif OS.get_cmdline_user_args().has("--overlayglb"):
		await _run_overlay_glb()
	else:
		await _run_preview()
	get_tree().quit()


## Which paint mechanisms actually render in this project's GL Compatibility
## renderer: four boxes, each with its own mesh — mesh material / material_override
## / material_overlay / nothing (the control).
func _run_overlay_test() -> void:
	var red := _material(Color(0.917647, 0.113725, 0.172549))
	for i in range(4):
		var mi := MeshInstance3D.new()
		mi.name = "Box%d" % i
		var box := BoxMesh.new()
		box.size = Vector3(0.5, 0.5, 0.5)
		mi.mesh = box
		mi.position = Vector3(i, 0.25, 0.0)
		match i:
			0:
				box.material = red
			1:
				mi.material_override = red
			2:
				mi.material_overlay = red
			3:
				pass
		_viewport.add_child(mi)
	await _shoot(OVERLAY_PATH, Vector3(1.5, 0.25, 0.0), 4.2, 0.0)
	print("[mascot] overlay test: 0=mesh.material 1=material_override 2=material_overlay 3=control")


## Does a material_overlay render on this GLB's mesh at all? Two toilets, both
## with a red overlay — one on my own MeshInstance3D (mesh resource shared with
## the GLB, not embedded), one inside the GLB instance. Both stay white, which is
## why the mascot scenes carry their geometry instead of instancing the .glb.
func _run_overlay_glb() -> void:
	var red := _material(Color(0.917647, 0.113725, 0.172549))
	var src := (load(TOILET) as PackedScene).instantiate() as Node3D
	var src_mesh := (src.get_node_or_null("toilet(Clone)") as MeshInstance3D).mesh
	var mine := MeshInstance3D.new()
	mine.name = "MeshOnOwnNode"
	mine.mesh = src_mesh
	mine.material_overlay = red
	mine.scale = Vector3.ONE * 0.475
	mine.rotation_degrees = Vector3(0.0, -90.0, 0.0)
	_viewport.add_child(mine)
	var model := (load(TOILET) as PackedScene).instantiate() as Node3D
	(model.get_node_or_null("toilet(Clone)") as MeshInstance3D).material_overlay = red
	model.position = Vector3(1.0, 0.0, 0.0)
	model.scale = Vector3.ONE * 2.0
	_viewport.add_child(model)
	src.free()
	await _shoot(OVERLAY_PATH, Vector3(0.5, 0.35, 0.0), 3.4, 0.0)
	print("[mascot] overlay-glb test: both toilets have a red overlay and both render white")


# ---------------------------------------------------------------------------
# The two modes
# ---------------------------------------------------------------------------

## The bare toilet alone: the game's pitch, then a near-top view, to see which
## surfaces the player actually looks at (seat, cistern top) and where the hat
## can stand.
func _run_probe() -> void:
	var def := _toilet_def()
	_place_def(def, Vector2i(0, 0), 0)
	_report(def, "toilet.glb", [])
	await _shoot(PROBE_PATH, Vector3(0.0, 0.35, 0.0), 2.6, 0.0)
	await _shoot(TOP_PATH, Vector3(0.0, 0.0, 0.0), 2.2, 0.0, 78.0)
	print("[mascot] probe: bare toilet at pitch 50 (%s) and pitch 78 (%s)" % [PROBE_PATH, TOP_PATH])


## The two mascots side by side, plus a bare toilet for comparison.
func _run_preview() -> void:
	var cell := FIRST_CELL
	for prop_id: String in PROPS:
		_place_prop(prop_id, cell)
		cell.x += 1
	_place_def(_toilet_def(), REFERENCE_CELL, 0)
	await _shoot(OUT_PATH, Vector3(0.5, 0.4, 0.0), ROW_DISTANCE, 0.0)
	await _shoot(DIAG_PATH, Vector3(0.5, 0.4, 0.0), ROW_DISTANCE, 45.0)
	await _shoot(CLOSE_PATH, Vector3(0.0, 0.5, 0.0), CLOSE_DISTANCE, 0.0)
	await _shoot(FAR_PATH, Vector3(1.0, 0.4, 0.0), FAR_DISTANCE, 0.0)
	await _shoot_census()
	await _run_ingame()
	print("[mascot] wrote %s, %s, %s, %s, %s and %s"
		% [OUT_PATH, DIAG_PATH, CLOSE_PATH, FAR_PATH, CENSUS_PATH, INGAME_PATH])


## Places both mascots through the REAL kitchen (place_furniture) — which runs
## its tint pass on every placement and would wipe a scene-authored override —
## and renders them in the game's own start kitchen, not a blank test layout.
func _run_ingame() -> void:
	_tiles.visible = false
	var kitchen := Kitchen.new()
	kitchen.name = "Kitchen"
	_viewport.add_child(kitchen)
	kitchen.load_layout("res://resources/layouts/start_kitchen.txt")
	var placed: Array[FurnitureInstance] = []
	for child in kitchen.get_node("Furniture").get_children():
		if child is FurnitureInstance and String((child as FurnitureInstance).def.id).begins_with("mascot_"):
			placed.append(child as FurnitureInstance)
	print("[mascot] start map places %d mascot(s): %s"
		% [placed.size(), _mascot_cells(placed)])
	# The map's second mascot sits on a cell with no floor (see tools/mascot_probe.gd
	# -- attract), so put the yellow one on a free cell of the same room for the shot.
	var yellow := FurnitureCatalog.find(&"mascot_yellow")
	for cell in [Vector2i(7, 5), Vector2i(7, 3), Vector2i(9, 3)]:
		if kitchen.can_place(yellow, cell, 0):
			var inst := kitchen.place_furniture(yellow, cell, 0)
			if inst != null:
				placed.append(inst)
				print("[mascot] placed the yellow mascot at %s for the shot" % cell)
			break
	for inst: FurnitureInstance in placed:
		var paint: Array = []
		_collect_paint(inst, String(inst.def.id), paint)
		print("[mascot] in-kitchen %-14s meshes=%d painted=%d" % [inst.def.id, inst.meshes().size(), paint.size()])
		for entry: Dictionary in paint:
			print("[mascot]   %-46s %s (slot=%s)" % [entry["path"], entry["color"], entry["slot"]])
	await _shoot(INGAME_PATH, Vector3(7.0, 0.4, 3.5), 5.0, 0.0)
	kitchen.queue_free()
	_tiles.visible = true


func _mascot_cells(instances: Array[FurnitureInstance]) -> PackedStringArray:
	var out := PackedStringArray()
	for inst: FurnitureInstance in instances:
		out.append("%s@%s" % [inst.def.id, inst.anchor])
	return out


# ---------------------------------------------------------------------------
# Scene setup
# ---------------------------------------------------------------------------

## 1 m checkered floor tiles with a hair of gap between them, so the cell each
## piece occupies is visible in the screenshot.
func _build_floor() -> void:
	_ground = MeshInstance3D.new()
	_ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 60.0)
	_ground.mesh = plane
	_ground.position = Vector3(0.0, -0.06, 0.0)
	_ground.material_override = _material(Color(0.22, 0.23, 0.26))
	_viewport.add_child(_ground)

	var tile := BoxMesh.new()
	tile.size = Vector3(0.98, 0.1, 0.98)
	# Mid-gray on purpose: a near-white checker clips the props to white (the
	# look is ACES + a bright ambient), which is exactly what this tool must show.
	var light := _material(Color(0.55, 0.57, 0.62))
	var dark := _material(Color(0.42, 0.44, 0.49))
	_tiles = Node3D.new()
	_tiles.name = "Tiles"
	_viewport.add_child(_tiles)
	for x in range(-6, 8):
		for z in range(-4, 5):
			var mi := MeshInstance3D.new()
			mi.mesh = tile
			mi.position = Vector3(x, -0.05, z)
			mi.material_override = light if ((x + z) & 1) == 0 else dark
			_tiles.add_child(mi)


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
		print("[mascot] FAIL - could not load %s" % path)
		return
	var def := FurnitureDef.new()
	def.id = StringName(prop_id)
	def.display_name = prop_id.capitalize()
	def.scene = packed
	def.scale_mult = 2.0
	_place_def(def, cell, 0)
	var expected: Array = EXPECTED.get(prop_id, [])
	_report(def, prop_id, expected)


## A FurnitureDef for the bare toilet model, for the side-by-side reference.
func _toilet_def() -> FurnitureDef:
	var def := FurnitureDef.new()
	def.id = &"toilet_reference"
	def.display_name = "Toilet (bare)"
	def.scene = load(TOILET) as PackedScene
	def.scale_mult = 2.0
	return def


## Places a furniture def (a prop or a plain kit model) on a cell.
func _place_def(def: FurnitureDef, cell: Vector2i, steps: int) -> void:
	if def == null:
		print("[mascot] FAIL - no def for cell %s" % cell)
		return
	var inst := FurnitureInstance.new()
	inst.name = String(def.id)
	inst.setup(def, cell, steps)
	_viewport.add_child(inst)
	inst.position = Vector3(cell.x, 0.0, cell.y)
	inst.rotation_degrees = Vector3(0.0, steps * 90.0 + def.yaw_offset_deg, 0.0)


# ---------------------------------------------------------------------------
# Measuring / reporting
# ---------------------------------------------------------------------------

## Prints the numbers FurnitureDef._measure() works from (footprint, floor
## contact) plus every authored colour in the scene, so the claim "painted in
## the scene" can be checked without trusting the render.
func _report(def: FurnitureDef, label: String, expected: Array) -> void:
	var node := def.scene.instantiate() as Node3D
	if node == null:
		print("[mascot] FAIL - %s is not a Node3D" % label)
		return
	var aabb := MeshBounds.combined_aabb(node)
	var footprint := def.resolved_footprint()
	var world := aabb.size * def.scale_mult * def.scale_axis
	var paint: Array = []
	_collect_paint(node, String(node.name), paint)
	node.free()
	print("[mascot] %-14s native aabb=(%.4f, %.4f, %.4f) min y=%.4f  world=(%.3f, %.3f, %.3f) m"
		% [label, aabb.size.x, aabb.size.y, aabb.size.z, aabb.position.y, world.x, world.y, world.z])
	print("[mascot] %-14s footprint=%s cells  on floor=%s  meshes=%d"
		% [label, str(footprint), str(is_zero_approx(aabb.position.y)), paint.size()])
	var mains := 0
	var subs := 0
	for entry: Dictionary in paint:
		var color: Color = entry["color"]
		var tag := "other"
		if expected.size() == 2:
			if _color_close(color, expected[0]):
				tag = "MAIN"
				mains += 1
			elif _color_close(color, expected[1]):
				tag = "SUB"
				subs += 1
		print("[mascot]   %-40s %s %-6s slot=%s"
			% [entry["path"], color.to_html(false), tag, entry["slot"]])
	print("[mascot] %-14s main meshes=%d sub meshes=%d  -> %s"
		% [label, mains, subs,
			"ok" if footprint == Vector2i.ONE and is_zero_approx(aabb.position.y) else "CHECK"])


## Every MeshInstance3D's live paint below [param node] as {path, color, slot}
## entries. The effective slot is the material_override, else the first surface
## override, else the material_overlay, else the mesh's own surface material —
## which is the one the kitchen leaves alone, so the in-kitchen report reads it.
func _collect_paint(node: Node, path: String, out: Array) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var color := Color(0.0, 0.0, 0.0, 0.0)
		var slot := ""
		if mi.material_override is BaseMaterial3D:
			color = (mi.material_override as BaseMaterial3D).albedo_color
			slot = "override"
		else:
			for i in mi.get_surface_override_material_count():
				var surface := mi.get_surface_override_material(i)
				if surface is BaseMaterial3D:
					color = (surface as BaseMaterial3D).albedo_color
					slot = "surface"
					break
			if slot.is_empty() and mi.material_overlay is BaseMaterial3D:
				color = (mi.material_overlay as BaseMaterial3D).albedo_color
				slot = "overlay"
			if slot.is_empty() and mi.mesh != null and mi.mesh.get_surface_count() > 0:
				var own := mi.mesh.surface_get_material(0)
				if own is BaseMaterial3D:
					color = (own as BaseMaterial3D).albedo_color
					slot = "mesh"
		if not slot.is_empty():
			out.append({"path": path, "color": color, "slot": slot})
	for child in node.get_children():
		_collect_paint(child, "%s/%s" % [path, child.name], out)


func _color_close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < 0.01 and absf(a.g - b.g) < 0.01 and absf(a.b - b.b) < 0.01


# ---------------------------------------------------------------------------
# Camera + screenshots + pixel census
# ---------------------------------------------------------------------------

## Moves the rig to a fixed framing, waits for the frame, saves a PNG.
func _shoot(path: String, focus: Vector3, distance: float, yaw: float, pitch := 50.0) -> Image:
	_rig.pitch_deg = pitch
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
	print("[mascot] screenshot %s (err=%d, %dx%d)" % [path, err, image.get_width(), image.get_height()])
	return image


## The census shot: floor tiles hidden and the ground darkened, so the only
## white and black pixels left in frame are the mascots' sub colours.
func _shoot_census() -> void:
	_tiles.visible = false
	var backup := _ground.material_override
	_ground.material_override = _material(CENSUS_BACKDROP)
	var image := await _shoot(CENSUS_PATH, Vector3(0.5, 0.4, 0.0), 3.4, 0.0)
	_tiles.visible = true
	_ground.material_override = backup
	_census(image)


## Counts the rendered pixels that fall in each colour family. This is the only
## proof that the authored paint is actually visible from the game camera.
func _census(image: Image) -> void:
	var counts := {"red": 0, "yellow": 0, "white": 0, "black": 0, "other": 0}
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x, y)
			var family := _family(c)
			counts[family] = int(counts[family]) + 1
	var total := image.get_width() * image.get_height()
	print("[mascot] census %s: red=%d yellow=%d white=%d black=%d other=%d (of %d px)"
		% [CENSUS_PATH, counts["red"], counts["yellow"], counts["white"], counts["black"],
			counts["other"], total])
	print("[mascot] census -> red visible=%s  yellow visible=%s  white sub visible=%s  black sub visible=%s"
		% [str(int(counts["red"]) > 200), str(int(counts["yellow"]) > 200),
			str(int(counts["white"]) > 50), str(int(counts["black"]) > 50)])


## Coarse colour family of a rendered pixel. Loose on purpose: the game's look
## (ACES tonemap, +10 % saturation) shifts every albedo.
func _family(c: Color) -> String:
	var hi := maxf(c.r, maxf(c.g, c.b))
	var lo := minf(c.r, minf(c.g, c.b))
	if hi < 0.16:
		return "black"
	if lo > 0.72 and hi - lo < 0.12:
		return "white"
	if c.r > 0.35 and c.r > c.g * 1.7 and c.r > c.b * 1.7:
		return "red"
	if c.r > 0.45 and c.g > 0.4 and c.b < c.g * 0.55 and c.r > c.b * 1.7:
		return "yellow"
	return "other"
