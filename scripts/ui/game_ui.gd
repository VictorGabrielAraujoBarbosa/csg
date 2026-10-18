extends CanvasLayer
## Player-facing UI: the kitchen frame (fullscreen while building, left with
## rounded corners during the day), the blueprint-dot backdrop, order cards,
## the build catalog, the Start Day button and the day summary.
##
## The 3D world lives in a SubViewport which is reparented under the frame here,
## so the whole restaurant can be laid out like a UI element.

const CLICK_SOUND := "res://assets/kenney_interface-sounds/Audio/click_002.ogg"
const CARD_SOUND := "res://assets/kenney_interface-sounds/Audio/drop_002.ogg"
const DONE_SOUND := "res://assets/kenney_interface-sounds/Audio/confirmation_001.ogg"
const DAY_SOUND := "res://assets/kenney_interface-sounds/Audio/bong_001.ogg"
const DENIED_SOUND := "res://assets/kenney_interface-sounds/Audio/back_002.ogg"

const BUILD_DISTANCE := 15.0
const DAY_DISTANCE := 16.0
const DAY_ANCHOR_RIGHT := 0.66
const CORNER_RADIUS := 26.0
## Time runs at a third speed while the customers are inside.
const HORROR_SLOW_MOTION := 0.35
const GLASS_SOUND := "res://assets/kenney_impact-sounds/Audio/impactGlass_heavy_000.ogg"

@export var day: DayController
@export var service: Service
@export var kitchen: Kitchen
@export var camera_rig: CameraRig
@export var placer: PlaceController
@export var paint: MapPaintController
@export var cutscene: CutsceneDirector
@export var world: SubViewport

var _backdrop: ColorRect
var _frame: TextureRect
var _frame_material: ShaderMaterial
var _money_label: Label
var _day_label: Label
var _start_button: Button
var _reason_label: Label
var _order_panel: PanelContainer
var _order_list: VBoxContainer
var _catalog_panel: PanelContainer
var _catalog_grid: GridContainer
var _catalog_status: Label
var _catalog_detail: PanelContainer
var _detail_icon: TextureRect
var _detail_name: Label
var _detail_price: Label
var _detail_info: Label
var _tab_group: ButtonGroup
var _shop_category: StringName = &""
var _summary: PanelContainer
var _summary_label: Label
var _cards: Dictionary = {}
var _horror_running := false
var _players: Array[AudioStreamPlayer] = []
var _player_index := 0
var _streams: Dictionary = {}


func _ready() -> void:
	if day == null:
		day = get_node_or_null("../World/DayController") as DayController
	if service == null:
		service = get_node_or_null("../World/Service") as Service
	if kitchen == null:
		kitchen = get_node_or_null("../World/Kitchen") as Kitchen
	if camera_rig == null:
		camera_rig = get_node_or_null("../World/CameraRig") as CameraRig
	if placer == null:
		placer = get_node_or_null("../World/PlaceController") as PlaceController
	if paint == null:
		paint = get_node_or_null("../World/MapPaintController") as MapPaintController
	if cutscene == null:
		cutscene = get_node_or_null("Cutscene") as CutsceneDirector
	if world == null:
		world = get_node_or_null("../World") as SubViewport

	_build_backdrop()
	_build_frame()
	_build_top_bar()
	_build_order_panel()
	_build_catalog()
	_build_summary()
	for i in 4:
		var player := AudioStreamPlayer.new()
		add_child(player)
		_players.append(player)

	if day != null:
		day.phase_changed.connect(_on_phase)
		day.day_finished.connect(_on_day_finished)
	if service != null:
		service.orders.changed.connect(_refresh_money)
		service.orders.order_added.connect(_on_order_added)
		service.orders.order_completed.connect(_on_order_completed)
		service.mob_started.connect(_on_mob_started)
	if kitchen != null:
		kitchen.layout_edited.connect(_refresh_money)
		kitchen.layout_rebuilt.connect(_refresh_money)
	if placer != null:
		placer.selection_changed.connect(_on_placer_selection)
	if paint != null:
		paint.hint.connect(_on_hint)
	_refresh_money()
	_on_phase(day.phase if day != null else DayController.Phase.BUILD)
	# Keep the developer overlay (hint / job counts / warnings) on top of the
	# player UI: children added at runtime draw after scene children.
	var dev := get_node_or_null("DevHud")
	if dev != null:
		move_child(dev, get_child_count() - 1)


# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _build_backdrop() -> void:
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = _dot_shader()
	_backdrop.material = mat
	_backdrop.visible = false
	add_child(_backdrop)


func _build_frame() -> void:
	# A TextureRect showing the world's viewport texture: unlike a
	# SubViewportContainer, its shader really receives the rendered image, so the
	# rounded-corner mask works. Input is forwarded manually below.
	_frame = TextureRect.new()
	_frame.name = "KitchenFrame"
	_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_frame.stretch_mode = TextureRect.STRETCH_SCALE
	_frame.mouse_filter = Control.MOUSE_FILTER_STOP
	_frame_material = ShaderMaterial.new()
	_frame_material.shader = _rounded_shader()
	_frame_material.set_shader_parameter("corner_radius", 0.0)
	_frame.material = _frame_material
	_frame.gui_input.connect(_on_frame_input)
	add_child(_frame)
	if world != null:
		_frame.texture = world.get_texture()
	_frame.resized.connect(_sync_world_size)
	_sync_world_size()


## Keeps the world viewport the same size as the on-screen frame, so forwarded
## mouse positions map 1:1.
func _sync_world_size() -> void:
	if world == null:
		return
	world.size = Vector2i(maxi(int(_frame.size.x), 2), maxi(int(_frame.size.y), 2))


func _on_frame_input(event: InputEvent) -> void:
	if world == null:
		return
	# _gui_input positions are already relative to this control, which matches
	# the viewport's coordinate space 1:1.
	world.push_input(event, true)


func _build_top_bar() -> void:
	var bar := PanelContainer.new()
	bar.name = "TopBar"
	bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	bar.offset_left = -560.0
	bar.offset_top = 10.0
	bar.offset_right = -12.0
	bar.offset_bottom = 74.0
	bar.add_theme_stylebox_override("panel", _panel_style())
	add_child(bar)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	bar.add_child(row)
	_money_label = Label.new()
	_money_label.add_theme_font_size_override("font_size", 22)
	row.add_child(_money_label)
	_day_label = Label.new()
	_day_label.add_theme_font_size_override("font_size", 18)
	_day_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_day_label)
	_reason_label = Label.new()
	_reason_label.add_theme_font_size_override("font_size", 13)
	_reason_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.45))
	row.add_child(_reason_label)
	_start_button = Button.new()
	_start_button.text = "Start Day"
	_start_button.custom_minimum_size = Vector2(140, 44)
	_start_button.pressed.connect(_on_start_pressed)
	row.add_child(_start_button)


func _build_order_panel() -> void:
	_order_panel = PanelContainer.new()
	_order_panel.name = "OrderPanel"
	_order_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_order_panel.anchor_left = DAY_ANCHOR_RIGHT
	_order_panel.offset_left = 6.0
	_order_panel.offset_top = 84.0
	_order_panel.offset_right = -12.0
	_order_panel.offset_bottom = -12.0
	_order_panel.add_theme_stylebox_override("panel", _panel_style())
	_order_panel.visible = false
	add_child(_order_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_order_panel.add_child(column)
	var title := Label.new()
	title.text = "CURRENT ORDERS"
	title.add_theme_font_size_override("font_size", 16)
	column.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	_order_list = VBoxContainer.new()
	_order_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_order_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_order_list)


func _build_catalog() -> void:
	_catalog_panel = PanelContainer.new()
	_catalog_panel.name = "Shop"
	_catalog_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_catalog_panel.anchor_right = 0.72
	_catalog_panel.offset_left = 12.0
	_catalog_panel.offset_top = -306.0
	_catalog_panel.offset_right = -12.0
	_catalog_panel.offset_bottom = -12.0
	_catalog_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(_catalog_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	_catalog_panel.add_child(column)
	# Header: title + category tabs.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	column.add_child(header)
	var title := Label.new()
	title.text = "SHOP"
	title.add_theme_font_size_override("font_size", 16)
	header.add_child(title)
	_tab_group = ButtonGroup.new()
	var categories: Array[StringName] = [&""]
	for category in FurnitureCatalog.shop_categories():
		categories.append(category)
	for category in categories:
		var tab := Button.new()
		tab.text = "All" if category == &"" else FurnitureCatalog.category_label(category)
		tab.toggle_mode = true
		tab.button_group = _tab_group
		tab.button_pressed = category == &""
		tab.custom_minimum_size = Vector2(84, 26)
		tab.add_theme_font_size_override("font_size", 13)
		tab.pressed.connect(_on_tab_pressed.bind(category))
		header.add_child(tab)
	_catalog_status = Label.new()
	_catalog_status.add_theme_font_size_override("font_size", 13)
	_catalog_status.add_theme_color_override("font_color", Color(1.0, 0.78, 0.45))
	_catalog_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_catalog_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	header.add_child(_catalog_status)
	# Body: card grid + detail panel.
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(scroll)
	_catalog_grid = GridContainer.new()
	_catalog_grid.columns = 4
	_catalog_grid.add_theme_constant_override("h_separation", 8)
	_catalog_grid.add_theme_constant_override("v_separation", 8)
	scroll.add_child(_catalog_grid)
	_catalog_detail = PanelContainer.new()
	_catalog_detail.custom_minimum_size = Vector2(196, 0)
	_catalog_detail.add_theme_stylebox_override("panel", _card_style())
	body.add_child(_catalog_detail)
	var detail_column := VBoxContainer.new()
	detail_column.add_theme_constant_override("separation", 4)
	_catalog_detail.add_child(detail_column)
	var detail_row := HBoxContainer.new()
	detail_row.add_theme_constant_override("separation", 8)
	detail_column.add_child(detail_row)
	_detail_icon = TextureRect.new()
	_detail_icon.custom_minimum_size = Vector2(44, 44)
	_detail_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	detail_row.add_child(_detail_icon)
	var detail_text := VBoxContainer.new()
	detail_row.add_child(detail_text)
	_detail_name = Label.new()
	_detail_name.add_theme_font_size_override("font_size", 15)
	detail_text.add_child(_detail_name)
	_detail_price = Label.new()
	_detail_price.add_theme_font_size_override("font_size", 14)
	_detail_price.add_theme_color_override("font_color", Color(0.72, 0.92, 0.6))
	detail_text.add_child(_detail_price)
	_detail_info = Label.new()
	_detail_info.add_theme_font_size_override("font_size", 12)
	_detail_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail_info.add_theme_color_override("font_color", Color(0.72, 0.76, 0.85))
	detail_column.add_child(_detail_info)
	_rebuild_shop(&"")


## Rebuilds the card grid for a category ("" = everything on sale).
func _rebuild_shop(category: StringName) -> void:
	_shop_category = category
	for child in _catalog_grid.get_children():
		child.queue_free()
	for def in FurnitureCatalog.shop_items():
		if category != &"" and def.category != category:
			continue
		var button := Button.new()
		button.text = "%s\n$%d" % [def.display_name, def.cost]
		button.custom_minimum_size = Vector2(150, 54)
		button.tooltip_text = ", ".join(def.tags)
		button.icon = _icon(def)
		button.add_theme_constant_override("icon_max_width", 34)
		button.toggle_mode = true
		button.set_meta("cost", def.cost)
		button.set_meta("id", def.id)
		button.pressed.connect(_on_catalog_pressed.bind(def.id))
		_catalog_grid.add_child(button)
	_refresh_money()
	_update_detail()


func _on_tab_pressed(category: StringName) -> void:
	_rebuild_shop(category)
	_play(CLICK_SOUND)


## The detail card follows whatever the placer currently has selected.
func _update_detail() -> void:
	var def: FurnitureDef = placer.current_def() if placer != null else null
	if def == null or not def.shop:
		_detail_icon.texture = null
		_detail_name.text = "Nothing selected"
		_detail_price.text = ""
		_detail_info.text = "Click a card to pick something to place."
		return
	_detail_icon.texture = _icon(def)
	_detail_name.text = def.display_name
	_detail_price.text = "$%d" % def.cost if def.cost > 0 else "free"
	var size := def.resolved_footprint()
	var lines := PackedStringArray()
	if not def.description.is_empty():
		lines.append(def.description)
	lines.append("%d x %d m   (%s)" % [size.x, size.y, ", ".join(def.tags)])
	lines.append("LMB place   R rotate")
	lines.append("RMB remove   (bought pieces refund)")
	_detail_info.text = "\n".join(lines)


func _build_summary() -> void:
	_summary = PanelContainer.new()
	_summary.name = "Summary"
	_summary.set_anchors_preset(Control.PRESET_CENTER)
	_summary.offset_left = -220.0
	_summary.offset_top = -120.0
	_summary.offset_right = 220.0
	_summary.offset_bottom = 120.0
	_summary.add_theme_stylebox_override("panel", _panel_style())
	_summary.visible = false
	add_child(_summary)
	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 18)
	_summary.add_child(column)
	_summary_label = Label.new()
	_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_summary_label.add_theme_font_size_override("font_size", 20)
	column.add_child(_summary_label)
	var next := Button.new()
	next.text = "Next day"
	next.custom_minimum_size = Vector2(200, 48)
	next.pressed.connect(_on_next_day_pressed)
	column.add_child(next)


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

func _on_phase(phase: int) -> void:
	match phase:
		DayController.Phase.BUILD:
			_tween_frame(1.0, 0.0, 0.0, CORNER_RADIUS, 0.0)
			_backdrop.visible = false
			_catalog_panel.visible = true
			_order_panel.visible = false
			_summary.visible = false
			_start_button.visible = true
			_day_label.text = "Day %d — build" % (day.day + 1 if day != null else 1)
			if camera_rig != null:
				camera_rig.set_distance(BUILD_DISTANCE)
			if placer != null:
				placer.set_enabled(true)
			if day != null and day.phase == DayController.Phase.SUMMARY:
				pass
			_refresh_money()
		DayController.Phase.DAY:
			_tween_frame(DAY_ANCHOR_RIGHT, 10.0, 10.0, CORNER_RADIUS, 26.0)
			_backdrop.visible = true
			_catalog_panel.visible = false
			_order_panel.visible = true
			_summary.visible = false
			_start_button.visible = false
			_clear_cards()
			if day != null:
				_day_label.text = "Day %d — service" % day.day
			if camera_rig != null:
				camera_rig.set_distance(DAY_DISTANCE)
			if placer != null:
				placer.set_enabled(false)
			_play(DAY_SOUND)
		DayController.Phase.SUMMARY:
			_summary.visible = true
			_play(DONE_SOUND)


func _tween_frame(anchor_right: float, inset_x: float, inset_top: float, _radius: float, radius: float) -> void:
	var tween := create_tween().set_parallel()
	tween.tween_property(_frame, "anchor_right", anchor_right, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_frame, "offset_left", inset_x, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_frame, "offset_top", inset_top, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_frame, "offset_right", -inset_x, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_frame, "offset_bottom", -inset_x, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_method(_set_corner_radius, float(_frame_material.get_shader_parameter("corner_radius")), radius, 0.5)


func _set_corner_radius(value: float) -> void:
	_frame_material.set_shader_parameter("corner_radius", value)


# ---------------------------------------------------------------------------
# Orders
# ---------------------------------------------------------------------------

func _on_order_added(order: Order) -> void:
	if day != null and day.phase != DayController.Phase.DAY:
		return
	_add_card(order)


func _on_order_completed(order: Order) -> void:
	var wrap: Control = _cards.get(order.id)
	if wrap == null:
		return
	_cards.erase(order.id)
	var card := wrap.get_child(0) as Control
	if card != null:
		var tween := create_tween().set_parallel()
		tween.tween_property(card, "modulate:a", 0.0, 0.3)
		tween.tween_property(wrap, "custom_minimum_size:y", 0.0, 0.3)
		tween.chain().tween_callback(wrap.queue_free)
	_play(DONE_SOUND)


func _clear_cards() -> void:
	for wrap: Control in _cards.values():
		wrap.queue_free()
	_cards.clear()


func _add_card(order: Order) -> void:
	var wrap := Control.new()
	wrap.custom_minimum_size = Vector2(0, 104)
	_order_list.add_child(wrap)
	var card := PanelContainer.new()
	card.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.add_theme_stylebox_override("panel", _card_style())
	wrap.add_child(card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)
	var photo := TextureRect.new()
	var dish := ItemCatalog.find(order.recipe_id)
	if dish != null and not dish.preview_path.is_empty():
		photo.texture = load(dish.preview_path)
	photo.custom_minimum_size = Vector2(72, 72)
	photo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(photo)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(info)
	var title := Label.new()
	title.text = order.dish_name
	title.add_theme_font_size_override("font_size", 17)
	info.add_child(title)
	for id: StringName in order.adds:
		info.add_child(_modifier_row(id))
	for id: StringName in order.removes:
		info.add_child(_modifier_row(id))
	_cards[order.id] = wrap
	# Slide down from above the panel.
	card.position.y = -120.0
	card.modulate.a = 0.0
	var tween := create_tween().set_parallel()
	tween.tween_property(card, "position:y", 0.0, 0.4).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "modulate:a", 1.0, 0.25)
	_play(CARD_SOUND)


func _modifier_row(id: StringName) -> HBoxContainer:
	var def := ModifierCatalog.find(id)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var icon := TextureRect.new()
	if def != null and not def.icon_path.is_empty():
		icon.texture = load(def.icon_path)
	icon.custom_minimum_size = Vector2(22, 22)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(icon)
	var label := Label.new()
	label.text = ModifierCatalog.label(id)
	label.add_theme_font_size_override("font_size", 14)
	row.add_child(label)
	return row


# ---------------------------------------------------------------------------
# Build phase
# ---------------------------------------------------------------------------

func _on_catalog_pressed(id: StringName) -> void:
	if placer == null:
		return
	placer.select_by_id(id)
	_update_detail()
	_play(CLICK_SOUND)


func _on_start_pressed() -> void:
	if day == null:
		return
	var reasons := day.can_start_day()
	if reasons.is_empty():
		_play(CLICK_SOUND)
		day.start_day()
	else:
		_reason_label.text = reasons[0]
		_play(DENIED_SOUND)


func _on_next_day_pressed() -> void:
	_play(CLICK_SOUND)
	if day != null:
		day.finish_day()


func _on_placer_selection(_text: String) -> void:
	_update_detail()


func _on_hint(text: String) -> void:
	_catalog_status.text = text


func _on_day_finished(summary: Dictionary) -> void:
	var tail := ""
	if bool(summary.get("lost", false)):
		tail = "\n" + str(summary.get("reason", ""))
	elif day != null:
		tail = "\n" + day.next_day_hint()
	_summary_label.text = "Day %d %s\n\nOrders served: %d\nMoney: $%d%s" % [
		int(summary.get("day", 0)),
		"LOST" if summary.get("lost", false) else "complete",
		int(summary.get("served", 0)),
		int(summary.get("money", 0)),
		tail]
	if bool(summary.get("lost", false)) and _horror_running:
		_finish_horror_cutscene(summary)
	else:
		_summary.visible = true


# ---------------------------------------------------------------------------
# The horror cutscene (customers break in and eat the staff)
# ---------------------------------------------------------------------------

## The mob is inside: letterbox in, slow motion, watch it happen. The title card
## and the summary follow when the day closes (see _on_day_finished).
func _on_mob_started(edges: Array) -> void:
	if cutscene == null or _horror_running:
		return
	_horror_running = true
	_catalog_panel.visible = false
	_order_panel.visible = false
	_start_button.visible = false
	cutscene.begin()
	cutscene.set_slow_motion(service, HORROR_SLOW_MOTION)
	_play(GLASS_SOUND)
	await cutscene.letterbox(true, 0.4)
	if not edges.is_empty():
		var edge: Vector3i = edges[0]
		await cutscene.focus_cell(Vector2i(edge.x, edge.y), 9.5, 0.9)
	await cutscene.vignette(0.55, 1.0)
	await cutscene.shake(0.12, 0.35)
	# Let the chase play out (skippable), then hold on the empty kitchen.
	while service != null and service.mob_active and cutscene != null \
			and not cutscene.skip_requested():
		await get_tree().create_timer(0.15).timeout
	if cutscene == null:
		return
	if service != null and not service.workers.is_empty():
		await cutscene.focus_cell(service.workers[0].spawn_cell, 12.0, 0.8)


func _finish_horror_cutscene(summary: Dictionary) -> void:
	var eaten := int(summary.get("eaten", 0))
	var subtitle := str(summary.get("reason", ""))
	if subtitle.is_empty():
		subtitle = "the kitchen is quiet now"
	await cutscene.title("DAY LOST", subtitle, 2.0)
	await cutscene.shake(0.3, 0.5)
	cutscene.set_slow_motion(service, 1.0)
	await cutscene.finish()
	_horror_running = false
	_summary.visible = true
	if service != null:
		service.sim_speed = 1.0


func _refresh_money() -> void:
	if service == null:
		return
	_money_label.text = "$%d" % service.orders.money
	if day != null and day.phase == DayController.Phase.BUILD:
		var reasons := day.can_start_day()
		_start_button.disabled = not reasons.is_empty()
		_reason_label.text = "" if reasons.is_empty() else reasons[0]
	for child in _catalog_grid.get_children():
		var button := child as Button
		if button != null and button.has_meta("cost"):
			var affordable := service.orders.can_afford(int(button.get_meta("cost")))
			button.disabled = not affordable
			button.modulate = Color.WHITE if affordable else Color(1, 1, 1, 0.45)
			button.button_pressed = button.get_meta("id") == (placer.current_def().id if placer != null and placer.current_def() != null else &"")
	if _detail_price != null:
		var def: FurnitureDef = placer.current_def() if placer != null else null
		if def != null and def.cost > 0 and not service.orders.can_afford(def.cost):
			_catalog_status.text = "Not enough money for the %s" % def.display_name
		elif _catalog_status.text.begins_with("Not enough money"):
			_catalog_status.text = ""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _play(path: String) -> void:
	if _players.is_empty():
		return
	if not _streams.has(path):
		_streams[path] = load(path)
	var player := _players[_player_index]
	_player_index = (_player_index + 1) % _players.size()
	player.stream = _streams[path]
	player.play()


func _icon(def: FurnitureDef) -> Texture2D:
	if def.icon_path.is_empty():
		return null
	return load(def.icon_path)


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.1, 0.92)
	style.border_color = Color(0.28, 0.32, 0.4, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(12)
	return style


func _card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.13, 0.16, 0.98)
	style.border_color = Color(0.3, 0.34, 0.42, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(10)
	return style


func _rounded_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
// Rounded-rect mask for the kitchen frame: fullscreen while building, rounded
// while the day runs. The signed-distance field keeps the corners antialiased.
uniform float corner_radius : hint_range(0.0, 200.0) = 0.0;

void fragment() {
	vec2 size = 1.0 / TEXTURE_PIXEL_SIZE;
	vec2 half_size = size * 0.5;
	vec2 q = abs(UV * size - half_size) - (half_size - vec2(corner_radius));
	float d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - corner_radius;
	float mask = 1.0 - smoothstep(-1.0, 1.0, d);
	if (mask <= 0.001) {
		discard;
	}
	COLOR = vec4(texture(TEXTURE, UV).rgb, mask);
}
"""
	return shader


func _dot_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
uniform vec4 bg_color : source_color = vec4(0.055, 0.06, 0.075, 1.0);
uniform vec4 dot_color : source_color = vec4(0.17, 0.185, 0.225, 1.0);
uniform float spacing = 26.0;
uniform float dot_radius = 1.5;

void fragment() {
	vec2 p = FRAGCOORD.xy;
	vec2 cell = mod(p, vec2(spacing)) - vec2(spacing * 0.5);
	float d = length(cell);
	float dot = 1.0 - smoothstep(dot_radius - 0.8, dot_radius + 0.8, d);
	COLOR = vec4(mix(bg_color.rgb, dot_color.rgb, dot), 1.0);
}
"""
	return shader
