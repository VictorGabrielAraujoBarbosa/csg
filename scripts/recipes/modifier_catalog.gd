class_name ModifierCatalog
## The order modifiers available in the prototype: three add-ons and three
## removals, as decided for Prototype 4.

const PREVIEWS := "res://assets/kenney_food-kit/Previews/"

static var _by_id: Dictionary = {}


static func all() -> Array[ModifierDef]:
	if _by_id.is_empty():
		_build()
	var out: Array[ModifierDef] = []
	for def: ModifierDef in _by_id.values():
		out.append(def)
	return out


static func find(id: StringName) -> ModifierDef:
	if _by_id.is_empty():
		_build()
	return _by_id.get(id)


## "No Cheese" -> "- no cheese", "Fries" -> "+ fries" (for order cards).
static func label(id: StringName) -> String:
	var def := find(id)
	if def == null:
		return String(id)
	return ("+ " if def.kind == ModifierDef.Kind.ADD else "- ") + def.display_name.to_lower()


static func clear_caches() -> void:
	_by_id.clear()


static func _build() -> void:
	_by_id.clear()
	_add(&"add_fries", "Fries", ModifierDef.Kind.ADD, &"fries", "fries.png")
	_add(&"add_sauce", "Sauce", ModifierDef.Kind.ADD, &"sauce", "soy.png")
	_add(&"add_cheese", "Extra Cheese", ModifierDef.Kind.ADD, &"cheese_slice", "cheese-cut.png")
	_add(&"no_meat", "No Meat", ModifierDef.Kind.REMOVE, &"patty_cooked", "meat-cooked.png")
	_add(&"no_cheese", "No Cheese", ModifierDef.Kind.REMOVE, &"cheese_slice", "cheese-cut.png")
	_add(&"no_salad", "No Salad", ModifierDef.Kind.REMOVE, &"salad", "salad.png")


static func _add(id: String, name: String, kind: int, item: StringName, icon: String) -> void:
	var def := ModifierDef.new()
	def.id = StringName(id)
	def.display_name = name
	def.kind = kind
	def.item = item
	def.icon_path = PREVIEWS + icon
	_by_id[def.id] = def
