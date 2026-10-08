class_name RecipeDef
extends Resource
## How to make an item at a station: inputs -> output.
##
## Recipes are the nodes of the recursive requirement tree the planner expands.
## A recipe with no inputs and [member is_source] set is "take this base
## ingredient from storage".

@export var id: StringName = &""
@export var display_name: String = ""
## Item produced, and how many.
@export var output: StringName = &""
@export var output_amount := 1
## Each input: {item: StringName, amount: int, needs_order: bool}. When
## needs_order is set the input must carry the same order payload (used for
## "tray with order" so a tray is never plated with somebody else's dish).
@export var inputs: Array = []
## Station capability required (matches FurnitureDef.tags / structural points).
@export var station_tag: StringName = &""
## How many simulation ticks a worker spends operating the station.
@export var duration_ticks := 20
## Optional side effect when the recipe completes: "complete_order".
@export var effect: StringName = &""
## Source recipes are pulled from a storage station instead of being crafted.
@export var is_source := false
## How the output gets its payload: "" (none), "order" (stamp the job's order),
## "order_dish" (copy the needs_order input's payload and add the dish).
@export var stamp: StringName = &""


func input_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for entry in inputs:
		out.append(str(entry.get("item", "")))
	return out


func amount_for(item_id: StringName) -> int:
	for entry in inputs:
		if StringName(entry.get("item", "")) == item_id:
			return int(entry.get("amount", 1))
	return 0
