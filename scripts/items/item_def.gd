class_name ItemDef
extends Resource
## An item that can exist in the world: a food ingredient or a tray.
## Base ingredients are pulled from a storage station; everything else is made
## by a recipe.

@export var id: StringName = &""
@export var display_name: String = ""
## Base mesh. Food kit models are ~3.3 units/m, so they usually need scale ~0.3.
@export var scene: PackedScene
@export var scale_mult := 0.3
## Optional extra mesh stacked on top (e.g. a ticket, or a dish on a tray).
@export var extra_scene: PackedScene
@export var extra_scale := 0.3
@export var extra_offset := Vector3(0.0, 0.06, 0.0)
## When set, the extra mesh comes from the item's payload under this key
## (used by tray_with_finished_order to show the actual dish).
@export var extra_from_payload: StringName = &""
## Colour multiplied over the base mesh (used for the dirty tray).
@export var tint := Color.WHITE
## Base ingredients are taken from a station with [member source_tag].
@export var is_base := false
@export var source_tag: StringName = &"storage"
## Where an item of this kind stands in for a structure marker (order trays
## should not be tinted by the colour tools).
@export var tag: StringName = &""


func is_tray() -> bool:
	return tag == &"tray"
