extends SceneTree
## Dev utility for the two mascot props (res://resources/props/mascot_*.tscn).
##
##   godot --headless --path . -s res://tools/mascot_probe.gd -- top
##     Vertex analysis of the Kenney toilet: where the cistern's flat lid is
##     (that is where the hat stands) and where the bowl is. This is how the
##     prop's part positions were measured.
##
##   godot --headless --path . -s res://tools/mascot_probe.gd -- kitchen
##     Places both props through the real Kitchen.place_furniture() and prints
##     what is left of their paint. The kitchen's tint pass clears a piece's
##     material_override and every surface override, so this is the check that
##     the mascots really keep their colours in the restaurant.
##
##   godot --headless --path . -s res://tools/mascot_probe.gd -- generate
##     Writes the two mascot scenes (see the generation section below).
##
## For the render side of the same story see tools/mascot_preview.gd.

const TOILET := "res://assets/kenney_furniture-kit/Models/GLTF format/toilet.glb"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("top"):
		_probe_top()
	elif args.has("kitchen"):
		_probe_kitchen()
	elif args.has("attract"):
		await _probe_attract(args.has("strip"))
	elif args.has("generate"):
		_generate_mascots()
	else:
		print("usage: -s res://tools/mascot_probe.gd -- top | kitchen | attract [strip] | generate")
	quit()


# ---------------------------------------------------------------------------
# top — where the toilet's parts are
# ---------------------------------------------------------------------------

## Walks the actual vertices of the toilet mesh in root space and reports where
## the high and low parts sit, so the cistern (the flat top a hat can stand on)
## is known without guessing from a render.
func _probe_top() -> void:
	var root := load(TOILET).instantiate() as Node3D
	var points := PackedVector3Array()
	_collect_vertices(root, root.transform, points)
	print("vertices=%d" % points.size())
	var max_y := -INF
	for p in points:
		max_y = maxf(max_y, p.y)
	var band := 0.02
	var top := AABB()
	var found := false
	for p in points:
		if p.y >= max_y - band:
			var one := AABB(p, Vector3.ZERO)
			top = one if not found else top.merge(one)
			found = true
	print("max y=%.4f  top band (>%.3f) x=[%.4f..%.4f] z=[%.4f..%.4f] centre=(%.4f, %.4f)"
		% [max_y, max_y - band, top.position.x, top.end.x, top.position.z, top.end.z,
			(top.position.x + top.end.x) * 0.5, (top.position.z + top.end.z) * 0.5])
	print("column heights (2 cm grid, rows = z, cols = x):")
	var cols := 16
	var rows := 24
	var grid := []
	grid.resize(cols * rows)
	grid.fill(0.0)
	for p in points:
		var cx := clampi(int(p.x / 0.02), 0, cols - 1)
		var cz := clampi(int(p.z / 0.02), 0, rows - 1)
		grid[cz * cols + cx] = maxf(grid[cz * cols + cx], p.y)
	for cz in range(rows - 1, -1, -1):
		var line := "  z=%.2f " % (cz * 0.02)
		for cx in range(cols):
			var h: float = grid[cz * cols + cx]
			if h <= 0.0:
				line += " . "
			elif h > max_y - 0.06:
				line += " # "
			elif h > 0.3:
				line += " + "
			else:
				line += " - "
		print(line)
	print("  x ->    0.00             0.30")
	root.free()


## Appends every vertex of every surface below [param node], in root space.
func _collect_vertices(node: Node, xf: Transform3D, out: PackedVector3Array) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var node_xf := xf
			for i in mi.mesh.get_surface_count():
				var arrays := mi.mesh.surface_get_arrays(i)
				var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				for v in verts:
					out.append(node_xf * v)
	for child in node.get_children():
		var child_xf := xf
		if child is Node3D:
			child_xf = xf * (child as Node3D).transform
		_collect_vertices(child, child_xf, out)


# ---------------------------------------------------------------------------
# kitchen — does the paint survive a placement?
# ---------------------------------------------------------------------------

## Places the mascot props through the REAL kitchen path (place_furniture), then
## reports what is left of the scene-authored paint.
func _probe_kitchen() -> void:
	var kitchen := Kitchen.new()
	root.add_child(kitchen)
	kitchen.new_layout(Vector2i(8, 8))
	var cell := Vector2i(2, 2)
	for id in [&"mascot_red", &"mascot_yellow"]:
		var def := FurnitureCatalog.find(id)
		if def == null:
			print("FAIL - no catalog def for %s" % id)
			continue
		print("=== %s (scene=%s)" % [id, def.scene])
		var inst := kitchen.place_furniture(def, cell, 0)
		cell.x += 2
		if inst == null:
			print("  FAIL - place_furniture returned null")
			continue
		var live: Array = []
		_collect_paint(inst, "inst", live)
		print("  after placement, meshes=%d" % live.size())
		for entry: Dictionary in live:
			print("    %-46s override=%s overlay=%s mesh_material=[%s]"
				% [entry["path"], entry["override"], entry["overlay"], ", ".join(entry["own"])])
		inst.free()
	kitchen.free()


## Every MeshInstance3D's live material state below [param node]: what is left of
## the scene-authored override, the surface overrides, the overlay, and what the
## mesh itself carries.
func _collect_paint(node: Node, path: String, out: Array) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var own := PackedStringArray()
		if mi.mesh != null:
			for i in mi.mesh.get_surface_count():
				own.append(_mat_color(mi.mesh.surface_get_material(i)))
		out.append({
			"path": path,
			"override": _mat_color(mi.material_override),
			"overlay": _mat_color(mi.material_overlay),
			"own": own,
		})
	for child in node.get_children():
		_collect_paint(child, "%s/%s" % [path, child.name], out)


func _mat_color(mat: Material) -> String:
	if mat is BaseMaterial3D:
		return (mat as BaseMaterial3D).albedo_color.to_html(false)
	return "(none)"


# ---------------------------------------------------------------------------
# attract — do the mascots block the showreel kitchen?
# ---------------------------------------------------------------------------

## Reproduces the capture tool's attract-loop test (lend the starter kitchen its
## storage, ask for a real dish, let the chibis work for 400 ticks) on the real
## main scene, with the map as authored — or with the mascots removed first, so
## the two runs say whether the props cost the showreel its service.
func _probe_attract(strip: bool) -> void:
	var scene := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var kitchen := scene.find_child("Kitchen", true, false) as Kitchen
	var service := scene.find_child("Service", true, false) as Service
	var ui := scene.find_child("UI", true, false) as Node
	if kitchen == null or service == null or ui == null:
		print("FAIL - main.tscn is missing its Kitchen, Service or UI")
		return
	print("mascots in the map: %s" % str(_mascot_cells(kitchen)))
	# Why a mascot in the map file may not have made it into the room.
	for id in [&"mascot_red", &"mascot_yellow"]:
		var def := FurnitureCatalog.find(id)
		for cell in [Vector2i(7, 2), Vector2i(9, 5)]:
			print("  %s at %s: floor=%s placeable=%s occupied=%s"
				% [id, cell, str(kitchen.has_floor(cell)), str(kitchen.can_place(def, cell, 0)),
					str(kitchen.furniture_at(cell) != null)])
	_print_room(kitchen)
	if strip:
		for inst: FurnitureInstance in _mascot_instances(kitchen):
			kitchen.remove_furniture(inst, false)
		service.rebuild_stations()
		print("after stripping them: %s" % str(_mascot_cells(kitchen)))
	service.sim_speed = 0.0
	ui.call("_ensure_attract_stock")
	var lent: PackedStringArray = []
	for inst: FurnitureInstance in _placed(kitchen):
		if not kitchen.data.furniture.has(kitchen.furniture_entry(inst)):
			lent.append(String(inst.def.id))
	print("lent pieces: [%s]" % ", ".join(lent))
	ui.call("_attract_step")
	var pending: int = service.orders.active_orders().size()
	var completed_before: int = service.orders.completed_count
	service.run_ticks(400)
	print("attract: pending=%d  completed %d -> %d  money=%d  warnings=%s"
		% [pending, completed_before, service.orders.completed_count, service.orders.money,
			str(service.orders.completed_count > completed_before)])
	scene.free()


## A small floor map, so a map edit can pick a real cell. The mascot columns are
## marked with 'M' for the cells the map file asks for.
func _print_room(kitchen: Kitchen) -> void:
	var bounds := kitchen.data.floor_bounds()
	print("room (x %d..%d, z %d..%d): '#'=no floor, '.'=free, 'o'=occupied"
		% [bounds.position.x, bounds.end.x - 1, bounds.position.y, bounds.end.y - 1])
	var wanted := [Vector2i(7, 2), Vector2i(9, 5)]
	for z in range(bounds.position.y, bounds.end.y):
		var line := "  z=%2d " % z
		for x in range(bounds.position.x, bounds.end.x):
			var cell := Vector2i(x, z)
			if not kitchen.has_floor(cell):
				line += " #" if not wanted.has(cell) else " X"
			elif kitchen.furniture_at(cell) != null:
				line += " o"
			elif wanted.has(cell):
				line += " M"
			else:
				line += " ."
		print(line)


## The mascot cells currently placed in the kitchen.
func _mascot_cells(kitchen: Kitchen) -> PackedStringArray:
	var out := PackedStringArray()
	for inst: FurnitureInstance in _mascot_instances(kitchen):
		out.append("%s@%s" % [inst.def.id, inst.anchor])
	return out


## Every placed piece lives under the kitchen's own "Furniture" node.
func _placed(kitchen: Kitchen) -> Array[FurnitureInstance]:
	var out: Array[FurnitureInstance] = []
	var holder := kitchen.get_node_or_null("Furniture")
	if holder == null:
		return out
	for child in holder.get_children():
		if child is FurnitureInstance:
			out.append(child as FurnitureInstance)
	return out


func _mascot_instances(kitchen: Kitchen) -> Array[FurnitureInstance]:
	var out: Array[FurnitureInstance] = []
	for inst: FurnitureInstance in _placed(kitchen):
		if String(inst.def.id).begins_with("mascot_"):
			out.append(inst)
	return out


# ---------------------------------------------------------------------------
# generate — write the two mascot scenes
# ---------------------------------------------------------------------------

## The two mascots are hand-designed, but the toilet's geometry is carried in
## them as data (an ArrayMesh per surface) instead of a GLB instance. Reason: the
## only paint slot the game leaves alone. The kitchen's tint pass
## (Kitchen._apply_furniture_tints, run on every placement) clears a piece's
## material_override and every surface override, and material_overlay — although
## it renders on ordinary meshes — renders nothing for this GLB's ArrayMesh in
## the GL Compatibility renderer (tools/mascot_preview.gd -- --overlayglb shows
## both halves of that). The mesh's own surface materials are therefore the one
## place a scene can carry the colour and have the player see it, so the scenes
## own the geometry and put mascot_main / mascot_sub on its surfaces, with the
## same colours also set as material_override (the paint the brief asks for: it
## shows in the editor and whenever the scene is instantiated raw, and the drag
## ghost can still take that slot over).
const MASCOTS := [
	{
		"root": "MascotRed",
		"path": "res://resources/props/mascot_red.tscn",
		"main": Color(0.91764706, 0.11372549, 0.17254902),
		"sub": Color(1, 1, 1),
		"app": "red delivery app",
		"main_hex": "#EA1D2C",
		"sub_hex": "#FFFFFF",
		"other": "The yellow mascot is the same geometry with the two colours swapped",
	},
	{
		"root": "MascotYellow",
		"path": "res://resources/props/mascot_yellow.tscn",
		"main": Color(1, 0.82352941, 0),
		"sub": Color(0.06274510, 0.06274510, 0.06274510),
		"app": "yellow delivery app",
		"main_hex": "#FFD200",
		"sub_hex": "#101010",
		"other": "The red mascot is the same geometry with the two colours swapped",
	},
]
## The toilet stands on the base plate.
const TOILET_LIFT := 0.02
const PLATE_SIZE := Vector3(0.45, 0.02, 0.488)
const PLATE_POS := Vector3(0.1563, 0.01, 0.2385)
## Centre of the hat on the cistern lid (its y is set per part below).
const HAT_X := 0.1563
const HAT_Z := 0.075


func _generate_mascots() -> void:
	for spec: Dictionary in MASCOTS:
		_generate_mascot(spec)


func _generate_mascot(spec: Dictionary) -> void:
	var main_mat := _mascot_material("mascot_main", spec["main"])
	var sub_mat := _mascot_material("mascot_sub", spec["sub"])
	var root := Node3D.new()
	root.name = String(spec["root"])

	var toilet := (load(TOILET) as PackedScene).instantiate() as Node3D
	toilet.name = "Toilet"
	toilet.position = Vector3(0.0, TOILET_LIFT, 0.0)
	root.add_child(toilet)
	_paint_model(toilet, main_mat, sub_mat)

	var plate := BoxMesh.new()
	plate.size = PLATE_SIZE
	_add_primitive(root, "BasePlate", plate, sub_mat, PLATE_POS)
	var brim := CylinderMesh.new()
	brim.top_radius = 0.085
	brim.bottom_radius = 0.085
	brim.height = 0.014
	brim.radial_segments = 16
	_add_primitive(root, "HatBrim", brim, sub_mat, Vector3(HAT_X, 0.478, HAT_Z))
	var crown := CylinderMesh.new()
	crown.top_radius = 0.052
	crown.bottom_radius = 0.052
	crown.height = 0.085
	crown.radial_segments = 16
	_add_primitive(root, "HatCrown", crown, sub_mat, Vector3(HAT_X, 0.5275, HAT_Z))

	_own_all(root)
	_clear_scene_paths(root)
	var packed := PackedScene.new()
	var err := packed.pack(root)
	root.free()
	if err != OK:
		print("FAIL - could not pack %s (err=%d)" % [spec["root"], err])
		return
	var path := String(spec["path"])
	err = ResourceSaver.save(packed, path)
	if err != OK:
		print("FAIL - could not save %s (err=%d)" % [path, err])
		return
	_finish_file(path, _mascot_header(spec))
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		print("wrote %s (%d bytes)" % [path, file.get_length()])
		file.close()


## The mascot paint material: flat matte plastic, named so the game's tint system
## can still identify it (it never tints it unless a map says so).
func _mascot_material(resource_name: String, color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = resource_name
	mat.albedo_color = color
	mat.roughness = 0.5
	return mat


## Gives the scene its own copy of every mesh below [param node] and paints it:
## the toilet body gets [param main_mat], the seat [param sub_mat]. Both the
## mesh's own surface materials and the material_override carry the colour.
func _paint_model(node: Node, main_mat: StandardMaterial3D, sub_mat: StandardMaterial3D) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var mat := sub_mat if mi.name == "cover" else main_mat
			mi.mesh = mi.mesh.duplicate(true)
			# The duplicate still points at the GLB's mesh as its shadow mesh,
			# which would drag a second, unpainted copy of the geometry into the
			# scene; the main mesh casts the shadow just as well.
			mi.mesh.shadow_mesh = null
			for i in mi.mesh.get_surface_count():
				mi.mesh.surface_set_material(i, mat)
			mi.material_override = mat
			mi.name = "Seat" if mi.name == "cover" else "Body"
	for child in node.get_children():
		_paint_model(child, main_mat, sub_mat)


## Adds one authored primitive to the prop, painted on both slots.
func _add_primitive(root: Node3D, name: String, mesh: PrimitiveMesh, mat: StandardMaterial3D,
		pos: Vector3) -> void:
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	root.add_child(mi)


## Makes every node below [param root] owned by it (what PackedScene.pack needs).
func _own_all(root: Node) -> void:
	var stack: Array[Node] = []
	for child in root.get_children():
		stack.append(child)
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		node.owner = root
		for child in node.get_children():
			stack.append(child)


## Forgets that the nodes came from the GLB, so pack() writes them out as plain
## nodes with the geometry embedded instead of as an instance of the .glb (which
## would put the unpainted original back on load).
func _clear_scene_paths(root: Node) -> void:
	root.scene_file_path = ""
	var stack: Array[Node] = []
	for child in root.get_children():
		stack.append(child)
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		node.scene_file_path = ""
		for child in node.get_children():
			stack.append(child)


## The scene's documentation block, written above the generated nodes.
func _mascot_header(spec: Dictionary) -> String:
	return """; Mascot prop — the %s. Deliberately never named anywhere: the
; piece is recognised purely by its two colours.
;
;   main  %s  the toilet itself (the character)
;   sub   %s  the seat / cistern lid, the base plate and the hat
;
; The paint is authored HERE, on the mesh instances, and never depends on the
; game's per-material tint names (carpetWhite / metalLight / metalDark). It sits
; on two slots at once, because they are cleared at different times:
;
;   * material_override on every mesh instance — the authored paint: it shows in
;     the editor and whenever the scene is instantiated raw, and the build
;     phase's drag ghost can take the slot over without leaving a stain.
;   * the meshes' OWN surface materials — what the player actually sees, because
;     Kitchen._apply_furniture_tints (run on every placement) clears a piece's
;     material_override and all of its surface overrides, and this renderer
;     (GL Compatibility) draws no material_overlay for this mesh. The geometry is
;     therefore carried in the scene as data (the Kenney toilet, unmodified)
;     instead of being instanced from the .glb, so the colour survives placement.
;
; Native kit units (FurnitureDef.scale_mult = 2 makes them metres):
;   toilet      0.313 x 0.451 x 0.477, tank at z 0..0.085, bowl towards +Z
;   base plate  0.450 x 0.020 x 0.488, the toilet stands on it (y = 0.02)
;   hat         brim r 0.085 + crown r 0.052, standing on the tank lid
; Everything stays inside x 0.51 / z 0.51, so the piece measures 1x1 cells and
; its lowest point is the floor (min y = 0).
;
; %s:
; only the colours differ, by design.
""" % [spec["app"], spec["main_hex"], spec["sub_hex"], spec["other"]]


## Puts [param header] between the [gd_scene] line and the resources, and keeps
## the file in the project's own style (format 3, readable ids, no editor
## unique ids, no unreferenced sub-resources).
func _finish_file(path: String, header: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		print("FAIL - could not read back %s" % path)
		return
	var text := file.get_as_text()
	file.close()
	var newline := text.find("\n")
	if newline < 0:
		print("FAIL - %s has no header line" % path)
		return
	var body := _rename_sub_resources(_strip_unique_ids(text.substr(newline + 1)))
	body = _drop_unused_sub_resources(body)
	var steps := 1 + body.count("[ext_resource") + body.count("[sub_resource")
	var out := FileAccess.open(path, FileAccess.WRITE)
	if out == null:
		print("FAIL - could not write %s" % path)
		return
	out.store_string("[gd_scene load_steps=%d format=3]\n\n%s\n%s" % [steps, header, body])
	out.close()


## Drops the editor's per-node `unique_id` attribute (Godot 4.7 writes it; the
## rest of the project's scenes do not have it).
func _strip_unique_ids(body: String) -> String:
	var lines := body.split("\n")
	var out := PackedStringArray()
	for line in lines:
		var idx := line.find(" unique_id=")
		if idx < 0:
			out.append(line)
			continue
		var end := line.find("]", idx + 1)
		if end < 0:
			out.append(line.substr(0, idx))
		else:
			out.append(line.substr(0, idx) + line.substr(end))
	return "\n".join(out)


## Gives the generated sub-resources readable ids (pack() invents random ones),
## so the scene reads like the hand-written props: the two paint materials by
## their resource_name, every mesh by the node that uses it.
func _rename_sub_resources(body: String) -> String:
	const NODE_MESH := {
		"Body": "ArrayMesh_body",
		"Seat": "ArrayMesh_seat",
		"BasePlate": "BoxMesh_plate",
		"HatBrim": "CylinderMesh_brim",
		"HatCrown": "CylinderMesh_crown",
	}
	var renames := {}
	var node := ""
	var sub := ""
	for line in body.split("\n"):
		if line.begins_with("[node name=\""):
			node = line.get_slice("\"", 1)
			sub = ""
		elif line.begins_with("[sub_resource "):
			sub = line.get_slice("\"", 3)
			node = ""
		elif line.begins_with("mesh = SubResource(\"") and NODE_MESH.has(node):
			renames[line.get_slice("\"", 1)] = NODE_MESH[node]
		elif line.begins_with("resource_name = \"mascot_"):
			renames[sub] = "StandardMaterial3D_%s" % line.get_slice("\"", 1).trim_prefix("mascot_")
	for old: String in renames:
		body = body.replace("\"%s\"" % old, "\"%s\"" % renames[old])
	return body


## Drops sub-resource blocks that nothing references. pack() writes the mesh the
## GLB node came with alongside the scene's own copy of it; the orphan is dead
## weight in the file (and a second, unpainted copy of the toilet geometry).
func _drop_unused_sub_resources(body: String) -> String:
	var out := PackedStringArray()
	var block := PackedStringArray()
	var block_id := ""
	for line in body.split("\n"):
		if line.begins_with("[sub_resource "):
			_flush_sub_block(out, block, block_id, body)
			block = PackedStringArray([line])
			block_id = line.get_slice("\"", 3)
		elif not block.is_empty() and line.begins_with("["):
			_flush_sub_block(out, block, block_id, body)
			block = PackedStringArray()
			block_id = ""
			out.append(line)
		elif block.is_empty():
			out.append(line)
		else:
			block.append(line)
	_flush_sub_block(out, block, block_id, body)
	return "\n".join(out)


func _flush_sub_block(out: PackedStringArray, block: PackedStringArray, block_id: String,
		body: String) -> void:
	if block.is_empty():
		return
	if body.count("\"%s\"" % block_id) <= 1:
		return
	for line in block:
		out.append(line)
