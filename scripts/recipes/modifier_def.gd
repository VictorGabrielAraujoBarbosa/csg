class_name ModifierDef
extends Resource
## One thing a customer can ask for on top of a dish: an extra (ADD) or an
## ingredient to leave out (REMOVE). Modifiers turn the base dish recipe into a
## runtime variant for that order.

enum Kind { ADD = 0, REMOVE = 1 }

@export var id: StringName = &""
@export var display_name: String = ""
@export var kind := Kind.ADD
## The item added to the tray (ADD) or the ingredient removed from the dish
## recipe (REMOVE).
@export var item: StringName = &""
## 64x64 preview used on the order card.
@export var icon_path := ""
