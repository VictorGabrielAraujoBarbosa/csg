extends Control
## Level designer: the authoring UI for maps (floors, walls, windows, doorways,
## structural points, decor) and the map files the game can start from.
##
## Opens with the map editor (M). It drives the same controllers the game uses:
## [MapPaintController] paints structure, [PlaceController] places furniture —
## in designer mode placement is free and the full catalog (including decor) is
## available, so a starting kitchen can be authored without touching money.
##
## Files live in [constant Kitchen.LAYOUT_DIR]; in an editor run they are written
## straight into the project, otherwise into the user:// folder.

const MAPS_DIR_FALLBACK := "user://maps"

@export var kitchen: Kitchen
@export var paint: MapPaintController
@export var placer: PlaceController
@export var service: Service
@export var camera_rig: CameraRig

var _panel: PanelContainer
var _tool_grid: GridContainer
var _tool_buttons: Array[Button] = []
var _tint_row: HBoxContainer
var _tint_buttons: Array[Button] = []
var _name_edit: LineEdit
var _file_picker: OptionButton
var _size_x: SpinBox
var _size_z: SpinBox
var _status: Label
var _mode_label: Label
var _decor_grid: GridContainer
var _decor_scroll: ScrollContainer
var _tool_tip := ""
var _tool_tip_until := 0.0
var _free_placement := true


func _ready() -> void:
	if kitchen == null:
		kitchen = get_node_or_null("../../World/Kitchen") as Kitchen
	if paint == null:
		paint = get_node_or_null("../../World/MapPaintController") as MapPaintController
	if placer == null:
		placer = get_node_or_null("../../World/PlaceController") as PlaceController
	if service == null:
		service = get_node_or_null("../../World/Service") as Service
	if camera_rig == null:
		camera_rig = get_node_or_null("../../World/CameraRig") as CameraRig
	_build_panel()
	if paint != null:
		paint.tool_changed.connect(_on_tool_changed)
		paint.hint.connect(_on_hint)
		_on_tool_changed(paint.tool_label())
	_refresh_files()
	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	if _tool_tip_until > 0.0 and Time.get_ticks_msec() / 1000.0 > _tool_tip_until:
		_tool_tip = ""
		_tool_tip_until = 0.0
	if paint != null and placer != null:
		_status.text = "%s   |   %s%s" % [
			paint.tool_label(), placer.selection_label(),
			"" if _tool_tip.is_empty() else "   |   " + _tool_tip]


## Shows or hides the designer (the map editor's M key drives this).
func set_designer_visible(value: bool) -> void:
	visible = value
	if value:
		# The game UI adds its kitchen frame at runtime, so bring the panel back
		# to the front every time it opens.
		var parent := get_parent()
		if parent != null:
			parent.move_child(self, parent.get_child_count() - 1)
	if placer != null:
		placer.free_placement = _free_placement if value else false


# ---------------------------------------------------------------------------
# Panel construction
# ---------------------------------------------------------------------------

func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.name = "DesignerPanel"
	_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel.offset_left = -296.0
	_panel.offset_top = 84.0
	_panel.offset_right = -12.0
	_panel.offset_bottom = -12.0
	_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_panel.add_child(column)
	var title := Label.new()
	title.text = "LEVEL DESIGNER"
	title.add_theme_font_size_override("font_size", 16)
	column.add_child(title)
	_mode_label = Label.new()
	_mode_label.add_theme_font_size_override("font_size", 12)
	_mode_label.add_theme_color_override("font_color", Color(0.7, 0.76, 0.86))
	column.add_child(_mode_label)
	# --- tools ---
	column.add_child(_section("TOOLS"))
	_tool_grid = GridContainer.new()
	_tool_grid.columns = 2
	_tool_grid.add_theme_constant_override("h_separation", 6)
	_tool_grid.add_theme_constant_override("v_separation", 4)
	column.add_child(_tool_grid)
	for i in MapPaintController.TOOL_COUNT:
		var button := Button.new()
		button.text = MapPaintController.TOOL_LABELS[i]
		button.custom_minimum_size = Vector2(126, 26)
		button.add_theme_font_size_override("font_size", 12)
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_on_tool_pressed.bind(i))
		_tool_grid.add_child(button)
		_tool_buttons.append(button)
	# --- colours ---
	column.add_child(_section("COLOUR"))
	_tint_row = HBoxContainer.new()
	_tint_row.add_theme_constant_override("separation", 4)
	column.add_child(_tint_row)
	if paint != null:
		for i in paint.tint_palette.size():
			var swatch := Button.new()
			swatch.custom_minimum_size = Vector2(24, 24)
			swatch.toggle_mode = true
			swatch.tooltip_text = "Tint %d" % (i + 1)
			var style := StyleBoxFlat.new()
			style.bg_color = paint.tint_palette[i]
			style.set_corner_radius_all(5)
			style.set_border_width_all(1)
			style.border_color = Color(0, 0, 0, 0.4)
			swatch.add_theme_stylebox_override("normal", style)
			var pressed_style: StyleBoxFlat = style.duplicate()
			pressed_style.border_color = Color(1, 1, 1, 0.95)
			pressed_style.set_border_width_all(2)
			swatch.add_theme_stylebox_override("pressed", pressed_style)
			swatch.pressed.connect(_on_tint_pressed.bind(i))
			_tint_row.add_child(swatch)
			_tint_buttons.append(swatch)
	# --- decor ---
	column.add_child(_section("DECOR  (free placement)"))
	_decor_scroll = ScrollContainer.new()
	_decor_scroll.custom_minimum_size = Vector2(0, 150)
	_decor_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(_decor_scroll)
	_decor_grid = GridContainer.new()
	_decor_grid.columns = 4
	_decor_grid.add_theme_constant_override("h_separation", 4)
	_decor_grid.add_theme_constant_override("v_separation", 4)
	_decor_scroll.add_child(_decor_grid)
	for def in FurnitureCatalog.all():
		if def.shop:
			continue
		var button := Button.new()
		button.custom_minimum_size = Vector2(56, 44)
		button.tooltip_text = "%s (%d x %d)" % [def.display_name, def.footprint.x, def.footprint.y]
		button.icon = _icon(def)
		button.add_theme_constant_override("icon_max_width", 34)
		button.pressed.connect(_on_decor_pressed.bind(def.id))
		_decor_grid.add_child(button)
	# --- files ---
	column.add_child(_section("MAP FILE"))
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 4)
	column.add_child(name_row)
	_name_edit = LineEdit.new()
	_name_edit.text = "start_kitchen"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.add_theme_font_size_override("font_size", 13)
	name_row.add_child(_name_edit)
	var save_button := Button.new()
	save_button.text = "Save"
	save_button.add_theme_font_size_override("font_size", 13)
	save_button.pressed.connect(_on_save_pressed)
	name_row.add_child(save_button)
	_file_picker = OptionButton.new()
	_file_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_file_picker.add_theme_font_size_override("font_size", 13)
	column.add_child(_file_picker)
	var load_row := HBoxContainer.new()
	load_row.add_theme_constant_override("separation", 4)
	column.add_child(load_row)
	var load_button := Button.new()
	load_button.text = "Load"
	load_button.add_theme_font_size_override("font_size", 13)
	load_button.pressed.connect(_on_load_pressed)
	load_row.add_child(load_button)
	var menu_button := Button.new()
	menu_button.text = "Save as menu kitchen"
	menu_button.add_theme_font_size_override("font_size", 13)
	menu_button.tooltip_text = "Writes menu_kitchen.txt — the map the main menu shows off"
	menu_button.pressed.connect(_on_menu_map_pressed)
	load_row.add_child(menu_button)
	var start_button := Button.new()
	start_button.text = "Use as start map"
	start_button.add_theme_font_size_override("font_size", 13)
	start_button.tooltip_text = "Saves this map as start_kitchen.txt — the map the game loads"
	start_button.pressed.connect(_on_start_map_pressed)
	load_row.add_child(start_button)
	var size_row := HBoxContainer.new()
	size_row.add_theme_constant_override("separation", 4)
	column.add_child(size_row)
	var size_label := Label.new()
	size_label.text = "New"
	size_label.add_theme_font_size_override("font_size", 13)
	size_row.add_child(size_label)
	_size_x = SpinBox.new()
	_size_x.min_value = 4
	_size_x.max_value = 40
	_size_x.value = 14
	_size_x.custom_minimum_size = Vector2(56, 0)
	size_row.add_child(_size_x)
	_size_z = SpinBox.new()
	_size_z.min_value = 4
	_size_z.max_value = 40
	_size_z.value = 12
	_size_z.custom_minimum_size = Vector2(56, 0)
	size_row.add_child(_size_z)
	var new_button := Button.new()
	new_button.text = "Blank"
	new_button.add_theme_font_size_override("font_size", 13)
	new_button.pressed.connect(_on_new_pressed)
	size_row.add_child(new_button)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 12)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Color(0.78, 0.84, 0.95))
	column.add_child(_status)


func _section(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.62, 0.68, 0.78))
	return label


# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

func _on_tool_pressed(index: int) -> void:
	if paint != null:
		paint.set_tool(index)


func _on_tool_changed(text: String) -> void:
	_mode_label.text = "Map edit ON  —  M to close"
	for i in _tool_buttons.size():
		_tool_buttons[i].button_pressed = paint != null and paint.tool == i
	for i in _tint_buttons.size():
		_tint_buttons[i].button_pressed = paint != null and paint.tint_index == i


func _on_tint_pressed(index: int) -> void:
	if paint == null:
		return
	paint.tint_index = index
	paint.tool_changed.emit(paint.tool_label())


func _on_decor_pressed(id: StringName) -> void:
	if placer == null:
		return
	placer.free_placement = true
	placer.select_by_id(id)


func _on_hint(text: String) -> void:
	_tool_tip = text
	_tool_tip_until = Time.get_ticks_msec() / 1000.0 + 4.0


func _on_save_pressed() -> void:
	var name := _sanitize(_name_edit.text)
	if name.is_empty():
		_hint("Give the map a name first")
		return
	var path := _maps_dir().path_join(name + ".txt")
	if kitchen.save_layout(path):
		_hint("Saved %s" % path)
		_refresh_files()
	else:
		_hint("Could not write %s" % path)


func _on_load_pressed() -> void:
	if _file_picker.selected < 0:
		return
	var path: String = _file_picker.get_item_metadata(_file_picker.selected)
	if kitchen.load_layout(path):
		_name_edit.text = path.get_file().get_basename()
		_hint("Loaded %s" % path)
	else:
		_hint("Could not read %s" % path)


func _on_start_map_pressed() -> void:
	var path := Kitchen.LAYOUT_DIR.path_join("start_kitchen.txt")
	if kitchen.save_layout(path):
		_name_edit.text = "start_kitchen"
		_hint("The game now starts from %s" % path)
		_refresh_files()
	else:
		_hint("Could not write %s (exports cannot write into res://)" % path)


## Writes the showreel map the main menu loads (see GameUI.MENU_LAYOUT).
func _on_menu_map_pressed() -> void:
	var path := Kitchen.LAYOUT_DIR.path_join("menu_kitchen.txt")
	if kitchen.save_layout(path):
		_name_edit.text = "menu_kitchen"
		_hint("The main menu now shows %s" % path)
		_refresh_files()
	else:
		_hint("Could not write %s (exports cannot write into res://)" % path)


func _on_new_pressed() -> void:
	kitchen.new_layout(Vector2i(int(_size_x.value), int(_size_z.value)))
	_hint("Blank %d x %d map" % [int(_size_x.value), int(_size_z.value)])


func _hint(text: String) -> void:
	_tool_tip = text
	_tool_tip_until = Time.get_ticks_msec() / 1000.0 + 6.0


func _refresh_files() -> void:
	_file_picker.clear()
	var names := Kitchen.layout_files()
	for file in names:
		_file_picker.add_item(file)
		_file_picker.set_item_metadata(_file_picker.item_count - 1,
			Kitchen.LAYOUT_DIR.path_join(file))


## Where maps are written: straight into the project when running from the
## editor, otherwise the user folder.
func _maps_dir() -> String:
	if OS.has_feature("editor"):
		return Kitchen.LAYOUT_DIR
	return MAPS_DIR_FALLBACK


func _sanitize(text: String) -> String:
	var out := text.strip_edges().to_lower().replace(" ", "_")
	var clean := ""
	for i in out.length():
		var c := out[i]
		if c.is_valid_identifier() or c == "_" or c == "-" or c.is_valid_int():
			clean += c
	return clean


func _icon(def: FurnitureDef) -> Texture2D:
	if def.icon_path.is_empty():
		return null
	return load(def.icon_path)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.1, 0.94)
	style.border_color = Color(0.3, 0.34, 0.42, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(10)
	return style
