class_name WorldItem
extends Node3D
## One item in the kitchen: a single unit (never a stack) with an optional
## payload (order stamp), a logical cell, a slot inside that cell and an
## optional job reservation.
##
## The simulation only knows about [member cell]; everything visual (position,
## interpolation between states, the arrival pop) runs on real time in
## [method _process] so animation smoothness never depends on the tick rate.

const POP_TIME := 0.22
const POP_HEIGHT := 0.12
const SETTLE_TIME := 0.15

var def: ItemDef
var payload: Dictionary = {}
var cell := Vector2i.ZERO
var reserved_by: Variant = null  # Job
var base_height := 0.05

var _visual := Vector3.ZERO
var _from := Vector3.ZERO
var _target := Vector3.ZERO
var _move_elapsed := 0.0
var _move_duration := 0.0
var _pop := 0.0
var _meshes: Array[Node3D] = []


func setup(item_def: ItemDef, item_payload: Dictionary, item_cell: Vector2i, height: float, tint := Color.WHITE) -> void:
	def = item_def
	payload = item_payload.duplicate()
	cell = item_cell
	base_height = height
	name = String(def.id)
	_build(tint)
	snap_to(cell_position(cell, height), true)


static func cell_position(item_cell: Vector2i, height: float) -> Vector3:
	return Vector3(item_cell.x, height, item_cell.y)


## Jumps straight to a position (spawning, or the sim catching up).
func snap_to(target: Vector3, pop := false) -> void:
	_visual = target
	position = target
	_from = target
	_target = target
	_move_elapsed = 0.0
	_move_duration = 0.0
	if pop:
		_pop = 1.0


## Starts a smooth journey; [param duration] is in real seconds.
func begin_move(target: Vector3, duration: float) -> void:
	_from = _visual
	_target = target
	_move_elapsed = 0.0
	_move_duration = maxf(duration, 0.001)


func is_moving() -> bool:
	return _move_duration > 0.0


## Settles into a new slot (stack fan) unless already travelling.
func set_layout_target(target: Vector3) -> void:
	if _move_duration > 0.0:
		return
	if _visual.distance_to(target) < 0.001:
		return
	begin_move(target, SETTLE_TIME)


## For tests: the currently displayed position.
func visual_position() -> Vector3:
	return _visual


func _process(delta: float) -> void:
	if _move_duration > 0.0:
		_move_elapsed = minf(_move_elapsed + delta, _move_duration)
		var t := _move_elapsed / _move_duration
		_visual = _from.lerp(_target, smoothstep(0.0, 1.0, t))
		if _move_elapsed >= _move_duration:
			_move_duration = 0.0
			_visual = _target
	var lift := 0.0
	if _pop > 0.0:
		_pop = maxf(_pop - delta / POP_TIME, 0.0)
		lift = sin((1.0 - _pop) * PI) * POP_HEIGHT
	position = _visual + Vector3(0.0, lift, 0.0)


func _build(tint: Color) -> void:
	var base := def.scene.instantiate() as Node3D
	base.scale = Vector3.ONE * def.scale_mult
	add_child(base)
	_apply_tint(base, tint)
	var aabb := MeshBounds.combined_aabb(base)
	var base_top := 0.0
	if aabb.size != Vector3.ZERO:
		# Centre on the cell and sit the model on the surface.
		var center := aabb.get_center()
		base.position -= Vector3(center.x, aabb.position.y, center.z)
		base_top = aabb.size.y
	_meshes.append(base)
	var extra_scene: PackedScene = def.extra_scene
	if def.extra_from_payload != &"" and payload.has(def.extra_from_payload):
		var extra_def := ItemCatalog.find(StringName(payload[def.extra_from_payload]))
		if extra_def != null:
			extra_scene = extra_def.scene
	if extra_scene != null:
		var extra := extra_scene.instantiate() as Node3D
		var extra_scale := def.extra_scale
		if def.extra_from_payload != &"" and payload.has(def.extra_from_payload):
			# A dish on a tray should keep its own size.
			var extra_def2 := ItemCatalog.find(StringName(payload[def.extra_from_payload]))
			if extra_def2 != null:
				extra_scale = extra_def2.scale_mult
		extra.scale = Vector3.ONE * extra_scale
		add_child(extra)
		var eaabb := MeshBounds.combined_aabb(extra)
		if eaabb.size != Vector3.ZERO:
			var ec := eaabb.get_center()
			extra.position -= Vector3(ec.x, eaabb.position.y, ec.z)
		extra.position += Vector3(0.0, base_top, 0.0) + def.extra_offset


## Multiplies the albedo of every surface so trays can be tinted (dirty, etc.).
func _apply_tint(node: Node, tint: Color) -> void:
	if tint.is_equal_approx(Color.WHITE):
		return
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if mi.mesh != null:
				for i in mi.mesh.get_surface_count():
					var src := mi.mesh.surface_get_material(i)
					if src is BaseMaterial3D:
						var mat := (src as BaseMaterial3D).duplicate() as BaseMaterial3D
						mat.albedo_color = mat.albedo_color * tint
						mi.set_surface_override_material(i, mat)
		_apply_tint(child, tint)


## Follows another node (a worker's hand) while being carried.
func attach_to(holder: Node3D, local_offset: Vector3) -> void:
	set_process(false)
	_move_duration = 0.0
	_pop = 0.0
	reparent(holder, false)
	position = local_offset
	rotation_degrees = Vector3.ZERO


## Returns to the world layer after a carry.
func detach_to(parent_node: Node3D, world_pos: Vector3) -> void:
	reparent(parent_node, false)
	set_process(true)
	snap_to(world_pos)


## Does this item satisfy a requirement? [param payload_match] values may be
## "$order" (the job's order id) or literals such as a dish variant id; an
## empty string matches an item without that payload key.
func matches(item_id: StringName, order_id: int, payload_match: Dictionary) -> bool:
	if def.id != item_id:
		return false
	for key: String in payload_match:
		var want: Variant = payload_match[key]
		if want == "$order":
			want = order_id
		var have: Variant = payload.get(key, "")
		if str(have) != str(want):
			return false
	return true


func describe() -> String:
	var extra := ""
	if payload.has("order"):
		extra = " (order %d)" % int(payload["order"])
	return "%s%s" % [def.display_name, extra]
