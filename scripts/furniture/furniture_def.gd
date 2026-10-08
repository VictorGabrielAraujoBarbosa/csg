class_name FurnitureDef
extends Resource
## Everything the game needs to know about a placeable object: the model, how
## many grid cells it occupies, its cost and its gameplay tags.

@export var id: StringName = &""
@export var display_name: String = ""
@export var scene: PackedScene
## Fallback footprint, used when [member auto_footprint] is off or the model
## cannot be measured.
@export var footprint: Vector2i = Vector2i.ONE
## Solid pieces block walking (and items sit on top). Non-solid pieces (mats,
## rugs) still own their cell for placement but can be walked over.
@export var solid := true
## Derive the footprint from the model's actual size (scaled), rounded up per
## axis, so multi-cell tables/sofas work without hand-measuring.
@export var auto_footprint := true
## Kenney's furniture kit is modelled at 1 unit = 0.5 m, so scale by 2.
@export var scale_mult: float = 2.0
## Optional per-axis extra scale (used to stretch the 3x1 assembly table).
@export var scale_axis := Vector3.ONE
## Station zoning for multi-cell pieces: each entry is
## {offset: Vector2i, role: "input" | "work" | "output"}. Rotates with the
## piece. Single-cell stations default to "the cell is input and output".
@export var zones: Array = []
## Extra yaw applied to the model (the blueprints of the kit face +Z by default).
@export var yaw_offset_deg: float = 0.0
@export var extra_offset: Vector3 = Vector3.ZERO
@export var cost: int = 0
@export var tags: Array[StringName] = []

var _auto_size := Vector2i.ZERO


func has_tag(tag: StringName) -> bool:
	return tags.has(tag)


## Footprint size after rotating an object by [param steps] * 90 degrees.
func rotated_footprint(steps: int) -> Vector2i:
	var size := resolved_footprint()
	return size if posmod(steps, 2) == 0 else Vector2i(size.y, size.x)


## All grid cells occupied by this object when anchored at [param anchor].
func cells(anchor: Vector2i, steps: int) -> Array[Vector2i]:
	var size := resolved_footprint()
	var out: Array[Vector2i] = []
	for dx in range(size.x):
		for dz in range(size.y):
			out.append(anchor + rotated_offset(Vector2i(dx, dz), steps))
	return out


## Offset from the anchor cell to the center of the footprint, in cell units.
func cell_center_offset(steps: int) -> Vector2:
	var size := resolved_footprint()
	var total := Vector2.ZERO
	var count := 0
	for dx in range(size.x):
		for dz in range(size.y):
			total += Vector2(rotated_offset(Vector2i(dx, dz), steps))
			count += 1
	return total / maxf(count, 1)


func resolved_footprint() -> Vector2i:
	if not auto_footprint:
		return footprint
	if _auto_size == Vector2i.ZERO:
		_auto_size = _measure()
	return _auto_size


func _measure() -> Vector2i:
	if scene == null:
		return footprint
	var node := scene.instantiate() as Node3D
	if node == null:
		return footprint
	var aabb := MeshBounds.combined_aabb(node)
	node.free()
	if aabb.size == Vector3.ZERO:
		return footprint
	var x := maxi(1, ceili(aabb.size.x * scale_mult - 0.02))
	var z := maxi(1, ceili(aabb.size.z * scale_mult - 0.02))
	return Vector2i(x, z)


## Rotates a cell offset by [param steps] * 90 degrees counter-clockwise.
static func rotated_offset(offset: Vector2i, steps: int) -> Vector2i:
	match posmod(steps, 4):
		1: return Vector2i(offset.y, -offset.x)
		2: return Vector2i(-offset.x, -offset.y)
		3: return Vector2i(-offset.y, offset.x)
	return offset
