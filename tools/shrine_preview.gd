extends Node3D
## Standalone preview for the corporate shrine (resources/props/corporate_shrine.tscn).
##
## The prop's job is to stop the two mascots reading as staff, so this tool puts
## the shrine next to the two things it must not be confused with: a bare worker
## toilet (toilet.glb at worker_scale with the service's default worker tint,
## 0.90 m tall) and a plain white toilet at the same scale. It places everything
## through the real furniture pipeline (FurnitureDef + FurnitureInstance: auto
## footprint from MeshBounds.combined_aabb, AABB centring, scale_mult = 2),
## prints the measured footprint and the authored paint, then renders the row
## with the game's camera rig (pitch 50) and counts the pixels.
##
## Run:
##   DISPLAY=:1 godot --path . res://tools/shrine_preview.tscn
## Writes into /tmp/opencode: shrine_preview.png (the row), shrine_preview_diag.png
## (yaw 40, the rail and plinth from the side), shrine_preview_close.png (the
## shrine alone), shrine_preview_far.png (build-phase distance), shrine_census.png
## (shrine alone on a dark backdrop, the shot the pixel census counts) and
## shrine_ingame.png (the shrine at its real cell in the start kitchen, placed by
## Kitchen.place_furniture, which is where a scene-authored paint has to survive
## the kitchen's tint pass).
##
## Every claim the prop makes is asserted here: footprint 2x1, min y 0, both
## mascot colours in both paint slots, the shrine characters 0.6 of the loose
## mascots, and red / yellow / white / black pixels actually on screen.

const OUT_PATH := "/tmp/opencode/shrine_preview.png"
const DIAG_PATH := "/tmp/opencode/shrine_preview_diag.png"
const CLOSE_PATH := "/tmp/opencode/shrine_preview_close.png"
const FAR_PATH := "/tmp/opencode/shrine_preview_far.png"
const CENSUS_PATH := "/tmp/opencode/shrine_census.png"
const INGAME_PATH := "/tmp/opencode/shrine_ingame.png"

const PROP_DIR := "res://resources/props/"
const TOILET := "res://assets/kenney_furniture-kit/Models/GLTF format/toilet.glb"
const START_MAP := "res://resources/layouts/start_kitchen.txt"

## The shrine takes cells (0, 0) and (1, 0); the references stand further right.
const SHRINE_CELL := Vector2i(0, 0)
const WORKER_CELL := Vector2i(3, 0)
const PLAIN_CELL := Vector2i(4, 0)
## What the shrine's mascots should measure against a full-size one.
const MASCOT_SCALE := 0.6
const EXPECTED_FOOTPRINT := Vector2i(2, 1)
## Main and sub colours of the two mascots, keyed by mascot id.
const EXPECTED := {
	"mascot_red": [Color("ea1d2c"), Color("ffffff")],
	"mascot_yellow": [Color("ffd200"), Color("101010")],
}

const FRAMES_BEFORE_SHOT := 30
const ROW_DISTANCE := 4.8
const CLOSE_DISTANCE := 2.6
const FAR_DISTANCE := 15.0
## Mid-gray census backdrop: far from white and black, so the sub colours of both
## mascots still count as their own family.
const CENSUS_BACKDROP := Color(0.26, 0.3, 0.38)

var _viewport: SubViewport
var _rig: CameraRig
var _tiles: Node3D
var _ground: MeshInstance3D
var _placed: Array[FurnitureInstance] = []
var _failures: PackedStringArray = []


func _ready() -> void:
	_viewport = get_node_or_null("Viewport") as SubViewport
	_rig = get_node_or_null("Viewport/CameraRig") as CameraRig
	if _viewport == null or _rig == null or _rig.camera == null:
		print("[shrine] FAIL - the preview scene is missing its viewport or camera rig")
		get_tree().quit()
		return
	_build_floor()
	await _run_preview()
	get_tree().quit()


func _run_preview() -> void:
	var def := _shrine_def()
	if def == null:
		_check(false, "the corporate_shrine scene loads", "could not load %s" % (PROP_DIR + "corporate_shrine.tscn"))
		return
	_report_shrine(def)
	_place_def(def, SHRINE_CELL, 0)
	_place_def(_toilet_def(&"worker_toilet", "Worker (bare)"), WORKER_CELL, 0)
	_place_def(_toilet_def(&"plain_toilet", "Toilet (plain white)"), PLAIN_CELL, 0)
	_tint_like_a_worker(_placed[1], Color(0.82, 0.88, 0.98))
	_report_references(def)
	await _shoot(OUT_PATH, Vector3(1.8, 0.4, 0.0), ROW_DISTANCE, 0.0)
	await _shoot(DIAG_PATH, Vector3(0.5, 0.4, 0.0), CLOSE_DISTANCE, 40.0)
	await _shoot(CLOSE_PATH, Vector3(0.5, 0.35, 0.0), CLOSE_DISTANCE, 0.0)
	await _shoot(FAR_PATH, Vector3(1.8, 0.4, 0.0), FAR_DISTANCE, 0.0)
	await _shoot_census()
	await _run_ingame()
	print("[shrine] wrote %s, %s, %s, %s, %s and %s"
		% [OUT_PATH, DIAG_PATH, CLOSE_PATH, FAR_PATH, CENSUS_PATH, INGAME_PATH])
	if _failures.is_empty():
		print("[shrine] ALL CHECKS PASSED")
	else:
		print("[shrine] %d CHECK(S) FAILED: %s" % [_failures.size(), ", ".join(_failures)])


# ---------------------------------------------------------------------------
# The pieces
# ---------------------------------------------------------------------------

## The catalog's own def when it exists (that is what the game will place),
## otherwise a locally built one with the same numbers.
func _shrine_def() -> FurnitureDef:
	var def := FurnitureCatalog.find(&"corporate_shrine")
	if def != null and def.scene != null:
		return def
	var packed := load(PROP_DIR + "corporate_shrine.tscn") as PackedScene
	if packed == null:
		return null
	var built := FurnitureDef.new()
	built.id = &"corporate_shrine"
	built.display_name = "Corporate Shrine"
	built.scene = packed
	built.scale_mult = 2.0
	return built


## A bare kit toilet, the shape both a worker and a loose mascot are built from.
func _toilet_def(id: StringName, label: String) -> FurnitureDef:
	var def := FurnitureDef.new()
	def.id = id
	def.display_name = label
	def.scene = load(TOILET) as PackedScene
	def.scale_mult = 2.0
	return def


## Places a furniture def on a cell, the way Kitchen._place_furniture_raw does
## (origin = the centre of the footprint).
func _place_def(def: FurnitureDef, cell: Vector2i, steps: int) -> FurnitureInstance:
	var inst := FurnitureInstance.new()
	inst.name = String(def.id)
	inst.setup(def, cell, steps)
	_viewport.add_child(inst)
	var off := def.cell_center_offset(steps)
	inst.position = Vector3(cell.x + off.x, 0.0, cell.y + off.y)
	inst.rotation_degrees = Vector3(0.0, steps * 90.0 + def.yaw_offset_deg, 0.0)
	_placed.append(inst)
	return inst


## The pale blue every worker without a painted post wears (Service.worker_tint),
## multiplied into the surfaces exactly like Worker._tint_body does it.
func _tint_like_a_worker(inst: FurnitureInstance, tint: Color) -> void:
	for mi in inst.meshes():
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(i)
			if src is BaseMaterial3D:
				var mat := (src as BaseMaterial3D).duplicate() as BaseMaterial3D
				mat.albedo_color = mat.albedo_color * tint
				mi.set_surface_override_material(i, mat)


# ---------------------------------------------------------------------------
# Measuring / reporting
# ---------------------------------------------------------------------------

## Prints the numbers FurnitureDef._measure() works from (footprint, floor
## contact) plus every authored colour in the scene, so the claim "the shrine is
## a 2x1 display painted red/white and yellow/black" can be checked without
## trusting the render.
func _report_shrine(def: FurnitureDef) -> void:
	var instance := def.scene.instantiate()
	if not instance is Node3D:
		_check(false, "corporate_shrine.tscn has a Node3D root", "the root is %s" % instance.get_class())
		instance.free()
		return
	var node := instance as Node3D
	var aabb := MeshBounds.combined_aabb(node)
	var footprint := def.resolved_footprint()
	var paint: Array = []
	_collect_paint(node, "CorporateShrine", paint)
	print("[shrine] native aabb=(%.4f, %.4f, %.4f) min y=%.4f  world=(%.3f, %.3f, %.3f) m"
		% [aabb.size.x, aabb.size.y, aabb.size.z, aabb.position.y,
			aabb.size.x * def.scale_mult, aabb.size.y * def.scale_mult, aabb.size.z * def.scale_mult])
	print("[shrine] footprint=%s cells (rotated 90 deg = %s)  on floor=%s  painted meshes=%d"
		% [str(footprint), str(def.rotated_footprint(1)), str(is_zero_approx(aabb.position.y)), paint.size()])
	_check(footprint == EXPECTED_FOOTPRINT, "the display measures %s cells" % str(EXPECTED_FOOTPRINT),
		"measured %s" % str(footprint))
	_check(is_zero_approx(aabb.position.y), "the display sits on the floor (min y 0)",
		"min y %.4f" % aabb.position.y)
	_check(aabb.size.x * def.scale_mult <= 2.01 and aabb.size.z * def.scale_mult <= 0.91,
		"the display fits its 2.00 x 0.90 m footprint",
		"%.3f x %.3f m" % [aabb.size.x * def.scale_mult, aabb.size.z * def.scale_mult])
	for entry: Dictionary in paint:
		print("[shrine]   %-44s %s slot=%s" % [entry["path"], (entry["color"] as Color).to_html(false), entry["slot"]])
	_check_mascot_paint(paint, "authored")
	# Then the same scene with every override cleared by hand — the state
	# Kitchen._apply_furniture_tints leaves a placed piece in. Only the colours
	# carried by the meshes' own surface materials are left to be seen.
	_strip_overrides(node)
	var bare: Array = []
	_collect_paint(node, "CorporateShrine", bare)
	node.free()
	for entry: Dictionary in bare:
		print("[shrine]   bare %-39s %s slot=%s" % [entry["path"], (entry["color"] as Color).to_html(false), entry["slot"]])
	_check_mascot_paint(bare, "after the kitchen's tint pass")


## Every mascot mesh carries its colour in both paint slots: the material_override
## (what the editor and a raw instance show, and what the drag ghost borrows) and
## the mesh's own surface material (what the kitchen's tint pass restores, so it
## is what the player sees).
func _check_mascot_paint(paint: Array, label: String) -> void:
	for mascot: String in EXPECTED:
		var main: Color = (EXPECTED[mascot] as Array)[0]
		var sub: Color = (EXPECTED[mascot] as Array)[1]
		var main_slots := PackedStringArray()
		var sub_slots := PackedStringArray()
		for entry: Dictionary in paint:
			if not String(entry["path"]).begins_with("CorporateShrine/%s/" % _node_name(mascot)):
				continue
			var color: Color = entry["color"]
			if _color_close(color, main):
				main_slots.append(String(entry["slot"]))
			elif _color_close(color, sub):
				sub_slots.append(String(entry["slot"]))
		print("[shrine] %-14s %-28s main %s in slots %s | sub %s in slots %s"
			% [mascot, label, main.to_html(false), ", ".join(main_slots), sub.to_html(false), ", ".join(sub_slots)])
		_check(main_slots.size() >= 1, "%s (%s) paints the main colour %s" % [mascot, label, main.to_html(false)],
			"no mesh carries it")
		_check(sub_slots.size() >= 1, "%s (%s) paints the sub colour %s" % [mascot, label, sub.to_html(false)],
			"no mesh carries it")


## Clears material_override and every surface override below [param node], the
## way Kitchen.clear_material_override + _restore_surface_overrides do it.
func _strip_overrides(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		mi.material_override = null
		for i in mi.get_surface_override_material_count():
			mi.set_surface_override_material(i, null)
	for child in node.get_children():
		_strip_overrides(child)


## Prints what the shrine's characters measure against the loose ones, so
## "clearly smaller" is a number and not an opinion.
func _report_references(def: FurnitureDef) -> void:
	# Native units for a scene root, metres for a placed FurnitureInstance
	# (its scale_mult is part of the transform MeshBounds measures through).
	var loose_scene := (load(PROP_DIR + "mascot_red.tscn") as PackedScene).instantiate() as Node3D
	var loose := MeshBounds.combined_aabb(loose_scene)
	loose_scene.free()
	var shrine_root := MeshBounds.combined_aabb(_placed[0])
	var worker := MeshBounds.combined_aabb(_placed[1])
	var shrine_mascot := 0.0
	for child in _placed[0].find_children("Mascot*", "Node3D", true, false):
		shrine_mascot = maxf(shrine_mascot, MeshBounds.combined_aabb(child as Node3D).size.y)
	var loose_m := loose.size.y * def.scale_mult
	var mascot_m := shrine_mascot * def.scale_mult
	var worker_m := worker.size.y
	print("[shrine] sizes: shrine=%.3f m tall (%.3f m wide)  worker toilet=%.3f m  loose mascot=%.3f m  shrine mascot=%.3f m"
		% [shrine_root.size.y, shrine_root.size.x, worker_m, loose_m, mascot_m])
	print("[shrine] the shrine's characters are %.2f of a loose mascot and %.2f of a worker"
		% [mascot_m / loose_m, mascot_m / worker_m])
	_check(absf(mascot_m / loose_m - MASCOT_SCALE) < 0.01,
		"the shrine's characters are %.2f of a loose mascot" % MASCOT_SCALE,
		"measured %.3f m against %.3f m" % [mascot_m, loose_m])
	_check(mascot_m < worker_m, "the shrine's characters are smaller than a worker toilet",
		"%.3f m vs %.3f m" % [mascot_m, worker_m])


func _node_name(mascot_id: String) -> String:
	return "MascotRed" if mascot_id.ends_with("red") else "MascotYellow"


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


func _check(ok: bool, claim: String, detail := "") -> void:
	if not ok:
		_failures.append(claim)
	print("[shrine] %s - %s%s" % ["ok" if ok else "FAIL", claim, "" if ok or detail.is_empty() else " (%s)" % detail])


# ---------------------------------------------------------------------------
# In the real kitchen
# ---------------------------------------------------------------------------

## The shrine as the game actually places it: the start map's own entry, built by
## Kitchen.load_layout -> place_furniture, which runs the tint pass that clears
## scene-authored overrides. If the colours survive here, they survive play.
func _run_ingame() -> void:
	_tiles.visible = false
	var kitchen := Kitchen.new()
	kitchen.name = "Kitchen"
	_viewport.add_child(kitchen)
	kitchen.load_layout(START_MAP)
	var shrine: FurnitureInstance = null
	for child in kitchen.get_node("Furniture").get_children():
		if child is FurnitureInstance and (child as FurnitureInstance).def.id == &"corporate_shrine":
			shrine = child as FurnitureInstance
	if shrine == null:
		_check(false, "the start map places a corporate_shrine", "no instance found")
		kitchen.queue_free()
		_tiles.visible = true
		return
	var paint: Array = []
	_collect_paint(shrine, "in-kitchen", paint)
	var mains := 0
	var subs := 0
	var slots := PackedStringArray()
	for entry: Dictionary in paint:
		var color: Color = entry["color"]
		var slot := String(entry["slot"])
		if not slots.has(slot):
			slots.append(slot)
		for mascot: String in EXPECTED:
			var expected: Array = EXPECTED[mascot]
			if _color_close(color, expected[0]):
				mains += 1
			elif _color_close(color, expected[1]):
				subs += 1
	print("[shrine] in-kitchen: %d meshes painted, main colours=%d, sub colours=%d, slots=%s"
		% [paint.size(), mains, subs, ", ".join(slots)])
	for entry: Dictionary in paint:
		print("[shrine]   in-kitchen %-38s %s slot=%s"
			% [entry["path"], (entry["color"] as Color).to_html(false), entry["slot"]])
	_check(mains >= 2 and subs >= 2, "the kitchen's tint pass leaves both mascot colours painted",
		"main=%d sub=%d" % [mains, subs])
	_check(slots.size() == 1 and slots[0] == "mesh", "in-kitchen paint comes from the meshes' own materials",
		"slots=%s" % ", ".join(slots))
	await _shoot(INGAME_PATH, shrine.position + Vector3(0.0, 0.4, 0.0), 4.4, 0.0)
	kitchen.queue_free()
	_tiles.visible = true


# ---------------------------------------------------------------------------
# Scene setup
# ---------------------------------------------------------------------------

## 1 m checkered floor tiles with a hair of gap between them, so the cells the
## piece occupies are visible in the screenshot.
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
	for x in range(-6, 10):
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
	print("[shrine] screenshot %s (err=%d, %dx%d)" % [path, err, image.get_width(), image.get_height()])
	return image


## The census shot: the references and the floor tiles hidden, the shrine's own
## plinth / kerb / plaque hidden too, and the ground darkened — so every white
## and black pixel left in frame is the mascots' own sub colour and the yellow
## count cannot be padded by the brass plaque. This shot is an instrument, not a
## portrait: the display itself is what the other five shots show.
func _shoot_census() -> void:
	_tiles.visible = false
	var hidden: Array[Node3D] = []
	for inst in _placed:
		if inst.def.id != &"corporate_shrine":
			inst.visible = false
	for child in _placed[0].get_child(0).get_children():
		if child is Node3D and not String(child.name).begins_with("Mascot"):
			(child as Node3D).visible = false
			hidden.append(child as Node3D)
	var backup := _ground.material_override
	_ground.material_override = _material(CENSUS_BACKDROP)
	var image := await _shoot(CENSUS_PATH, Vector3(0.5, 0.35, 0.0), 3.0, 0.0)
	_tiles.visible = true
	for inst in _placed:
		inst.visible = true
	for child in hidden:
		child.visible = true
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
	print("[shrine] census %s: red=%d yellow=%d white=%d black=%d other=%d (of %d px)"
		% [CENSUS_PATH, counts["red"], counts["yellow"], counts["white"], counts["black"],
			counts["other"], total])
	_check(int(counts["red"]) > 200, "the red mascot renders red", "%d px" % int(counts["red"]))
	_check(int(counts["yellow"]) > 200, "the yellow mascot renders yellow", "%d px" % int(counts["yellow"]))
	_check(int(counts["white"]) > 50, "the red mascot's white parts render white", "%d px" % int(counts["white"]))
	_check(int(counts["black"]) > 50, "the yellow mascot's black parts render black", "%d px" % int(counts["black"]))


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
