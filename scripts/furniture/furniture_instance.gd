class_name FurnitureInstance
extends Node3D
## A placed (or ghost) piece of furniture. Its origin is the center of its
## footprint, so [member position] can be set straight from the kitchen grid.

var def: FurnitureDef
var anchor: Vector2i = Vector2i.ZERO
var rot_steps: int = 0
## Height of the piece's top surface (world units) — where items sit on it.
var surface_y := 0.5
## Per-material colours: material name -> Color, with "*" meaning the whole
## piece. Empty = original look (see [method tint_for]).
var tints: Dictionary = {}
## Bought this session — only these sell back (venue furniture that came from
## the map file refunds nothing when it is removed).
var paid := false

var _model: Node3D
var _meshes: Array[MeshInstance3D] = []


func setup(p_def: FurnitureDef, p_anchor: Vector2i, p_steps: int) -> void:
	def = p_def
	anchor = p_anchor
	rot_steps = p_steps

	var src := def.scene.instantiate()
	if src is Node3D:
		_model = src
	else:
		_model = Node3D.new()
		_model.add_child(src)
	add_child(_model)

	# Center the model on its footprint, so rotations happen around the middle.
	var aabb := MeshBounds.combined_aabb(_model)
	if aabb.size != Vector3.ZERO:
		var center := aabb.get_center()
		_model.position -= Vector3(center.x, 0.0, center.z)
		# Height of the piece's top surface where items can sit.
		surface_y = aabb.end.y * def.scale_mult * def.scale_axis.y
	_model.position += def.extra_offset

	_collect_meshes()
	scale = Vector3.ONE * def.scale_mult * def.scale_axis
	rotation_degrees = Vector3(0.0, rot_steps * 90.0 + def.yaw_offset_deg, 0.0)


func footprint_cells() -> Array[Vector2i]:
	return def.cells(anchor, rot_steps)


## Sets (or clears, with white) the colour of one material group.
func set_tint(material_name: String, color: Color) -> void:
	if color.is_equal_approx(Color.WHITE):
		tints.erase(material_name)
	else:
		tints[material_name] = color


## Colour to apply to surfaces using [param material_name]: the exact material
## colour if painted, otherwise the whole-piece colour, otherwise white.
func tint_for(material_name: String) -> Color:
	if tints.has(material_name):
		return tints[material_name]
	if tints.has("*"):
		return tints["*"]
	return Color.WHITE


func has_tints() -> bool:
	return not tints.is_empty()


func meshes() -> Array[MeshInstance3D]:
	return _meshes


## Names of the materials this model uses (e.g. wood, metal, glass).
func material_names() -> PackedStringArray:
	var out := PackedStringArray()
	for mi in _meshes:
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(i)
			if mat != null and not mat.resource_name.is_empty() and not out.has(mat.resource_name):
				out.append(mat.resource_name)
	return out


func set_material_override_all(mat: Material) -> void:
	for mi in _meshes:
		mi.material_override = mat


## Drops the ghost / drag override so the piece shows its own materials again.
func clear_material_override() -> void:
	for mi in _meshes:
		mi.material_override = null


func _collect_meshes() -> void:
	_meshes.clear()
	var stack: Array[Node] = [_model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is MeshInstance3D:
			_meshes.append(node)
		for child in node.get_children():
			stack.append(child)
