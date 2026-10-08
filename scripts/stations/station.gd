class_name StationInstance
extends RefCounted
## A place items can sit and recipes can run: a placed furniture piece with
## capability tags, or a structural point (intake / delivery).
##
## Cells and zones are in grid space; multi-cell stations (the 3x1 assembly
## table) declare zones in [FurnitureDef.zones] which rotate with the piece.

var def: FurnitureDef          # null for structural points
var point_kind := -1           # KitchenLayout.PointKind, or -1
var tags: Array[StringName] = []
var cells: Array[Vector2i] = []
var input_cells: Array[Vector2i] = []
var output_cells: Array[Vector2i] = []
## Where a worker would stand to operate it (filled in by the service using
## the kitchen's walkability, may be empty).
var work_cells: Array[Vector2i] = []
## Job currently occupying it (instant executor / worker).
var busy_by: Variant = null


static func from_furniture(inst: FurnitureInstance) -> StationInstance:
	var station := StationInstance.new()
	station.def = inst.def
	station.tags = inst.def.tags
	var anchor := inst.anchor
	var steps := inst.rot_steps
	for dx in range(inst.def.resolved_footprint().x):
		for dz in range(inst.def.resolved_footprint().y):
			station.cells.append(anchor + FurnitureDef.rotated_offset(Vector2i(dx, dz), steps))
	if inst.def.zones.is_empty():
		station.input_cells = station.cells.duplicate()
		station.output_cells = station.cells.duplicate()
	else:
		for zone in inst.def.zones:
			var offset: Vector2i = zone.get("offset", Vector2i.ZERO)
			var cell: Vector2i = anchor + FurnitureDef.rotated_offset(offset, steps)
			match str(zone.get("role", "")):
				"input":
					station.input_cells.append(cell)
				"output":
					station.output_cells.append(cell)
				"work":
					station.work_cells.append(cell)
		if station.input_cells.is_empty():
			station.input_cells = station.cells.duplicate()
		if station.output_cells.is_empty():
			station.output_cells = station.cells.duplicate()
	return station


static func from_point(cell: Vector2i, kind: int) -> StationInstance:
	var station := StationInstance.new()
	station.point_kind = kind
	station.cells = [cell]
	station.input_cells = [cell]
	station.output_cells = [cell]
	station.tags = []
	station.tags.append(&"intake" if kind == KitchenLayout.PointKind.PICKUP else &"delivery")
	return station


func has_tag(tag: StringName) -> bool:
	return tags.has(tag)


func origin() -> Vector2i:
	return cells[0] if not cells.is_empty() else Vector2i.ZERO


## The cell a worker stands next to / operates from: a declared "work" zone for
## multi-cell stations, otherwise the station's own cell.
func work_target() -> Vector2i:
	return work_cells[0] if not work_cells.is_empty() else origin()


func input_cell() -> Vector2i:
	return input_cells[0] if not input_cells.is_empty() else origin()


func output_cell() -> Vector2i:
	return output_cells[0] if not output_cells.is_empty() else origin()


func describe() -> String:
	if point_kind >= 0:
		return "point#%d @%s" % [point_kind, origin()]
	return "%s @%s" % [def.id if def != null else "?", origin()]
