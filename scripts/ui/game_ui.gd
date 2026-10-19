extends CanvasLayer
## Player-facing UI: the kitchen frame (fullscreen while building, left with
## rounded corners during the day), the blueprint-dot backdrop, order cards,
## the build catalog, the Start Day button and the day summary.
##
## The 3D world lives in a SubViewport which is reparented under the frame here,
## so the whole restaurant can be laid out like a UI element.
##
## The game boots into a main menu drawn over that live kitchen ([member _menu]):
## until Start is pressed the shop, the order panel, the top bar and the placer
## are hidden and an attract loop keeps the chibis cooking with real orders
## ([method _attract_step]). [method start_game] leaves the menu, restores the
## phase UI and plays the [IntroSequence].
##
## A lost day is the end of the run: the horror chain ([method _on_mob_started])
## plays the chase, the DAY LOST card and the farewell card as one coroutine —
## [member _ending_busy] makes a second card structurally impossible — and then
## [method reset_to_menu] puts the player back at the main menu with the
## showreel running. A won day is untouched: its summary keeps the "Next day"
## button and the build phase.

const CLICK_SOUND := "res://assets/kenney_interface-sounds/Audio/click_002.ogg"
const CARD_SOUND := "res://assets/kenney_interface-sounds/Audio/drop_002.ogg"
const DONE_SOUND := "res://assets/kenney_interface-sounds/Audio/confirmation_001.ogg"
const DAY_SOUND := "res://assets/kenney_interface-sounds/Audio/bong_001.ogg"
const DENIED_SOUND := "res://assets/kenney_interface-sounds/Audio/back_002.ogg"

const BUILD_DISTANCE := 15.0
const DAY_DISTANCE := 16.0
## The menu wants the whole restaurant in frame around the title card.
## The menu camera pulls in close: the kitchen should fill most of the frame
## behind the title card.
const MENU_DISTANCE := 9.0
const DAY_ANCHOR_RIGHT := 0.66
const CORNER_RADIUS := 26.0
## "No cell": the attract stock's placement search returns this when the map has
## nowhere to put a lent piece.
const ATTRACT_NO_CELL := Vector2i(-1000000, -1000000)
## Time runs at a third speed while the customers are inside.
const HORROR_SLOW_MOTION := 0.35
## The three tracks the demo ships with, one per mood.
const MUSIC_BUILD := "res://assets/music/Airport%20Lounge - build.mp3"
const MUSIC_DAY := "res://assets/music/District%20Four - work.mp3"
const MUSIC_HORROR := "res://assets/music/Classic%20Horror%201 - lose.mp3"
const GLASS_SOUND := "res://assets/kenney_impact-sounds/Audio/impactGlass_heavy_000.ogg"

@export var day: DayController
@export var service: Service
@export var kitchen: Kitchen
@export var camera_rig: CameraRig
@export var placer: PlaceController
@export var paint: MapPaintController
@export var cutscene: CutsceneDirector
@export var world: SubViewport
@export var intro: IntroSequence

@export_group("Main menu")
## Title on the menu card drawn over the live kitchen.
@export var menu_title := "CONSUMER SATISFACTION (GUARANTEED)"
## One-line premise under the title.
@export var menu_premise := "A 99%-off sale, paid for by the delivery apps. Serve every order they send — or the customers come inside."
## The controls reminder on the menu card.
@export var menu_controls := "LMB place · RMB sell · R rotate · Esc deselect"
## The asset credit line (all kits are Kenney CC0).
@export var menu_credit := "Kenney CC0 asset kits (kenney.nl) · Music: Kevin MacLeod (incompetech.com) — CC BY 4.0"
## The map the main menu shows off, if the author has saved one.
const MENU_LAYOUT := "res://resources/layouts/menu_kitchen.txt"
## Seconds between attract-loop checks.
@export var attract_interval := 1.0
## Most orders the menu kitchen may have pending at once: keeps the loss rule
## (which counts pending orders) from ever firing behind the menu.
@export var attract_max_pending := 2
## Pieces the menu lends a kitchen that cannot cook yet. The shipped venue is
## missing its storage and sink (that is the day-1 lesson), so the showreel
## needs them; they are removed again by [method start_game].
@export var attract_stock: Array[StringName] = [
	&"shelf", &"fridge", &"sink", &"worker_post", &"worker_post"]

@export_group("Ending card")
## The farewell card, shown once after the horror sequence's DAY LOST.
@export var ending_title := "THANK YOU FOR PLAYING"
@export var ending_subtitle := "You have satisfied the customers.\nConsumer satisfaction: guaranteed."
## Seconds the farewell card stays up.
@export var ending_hold := 2.6

var _backdrop: ColorRect
var _frame: TextureRect
var _frame_material: ShaderMaterial
var _money_label: Label
var _day_label: Label
var _top_bar: PanelContainer
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
## The summary's continue button ("Next day" / "Start over"). Kept as a member:
## it lives inside the summary's column, so a name lookup from the panel missed it.
var _summary_button: Button
var _menu: PanelContainer
## What the detail card currently describes, so a per-frame refresh can early
## out ("grab:12", "hover:31", "select:fryer", "none:").
var _detail_key := ""
## The shop category tabs, in header order (All first).
var _tabs: Array[Button] = []
var _cards: Dictionary = {}
## Order id -> the countdown number label on its card.
var _card_timers: Dictionary = {}
## Order id -> the "angry in" caption above that number.
var _card_captions: Dictionary = {}
var _horror_running := false
## True while an ending sequence owns the cutscene director: the horror chase,
## the DAY LOST card, the farewell card and the return to the menu are one
## chain, and every other caller is turned away (see [method _on_mob_started]).
var _ending_busy := false
## The lost day's summary, handed over by [method _on_day_finished] while the
## horror chain is still on screen.
var _horror_summary: Dictionary = {}
## Set with [member _horror_summary]: the horror chain can play its cards.
var _horror_summary_ready := false
## True once Start has been pressed; before that the menu owns the screen and
## the attract loop runs behind it.
var _started := false
## Seconds until the attract loop's next look at the queue.
var _attract_clock := 0.0
## Which menu dish the attract loop asks for next.
var _attract_dish_index := -1
## The pieces the menu lent the kitchen; removed again when the game starts.
var _attract_pieces: Array[FurnitureInstance] = []
## The farewell card is a one-off: only the first lost day shows it.
var _ending_shown := false
## Who owns the shop status line ("afford" / "hint"), so it can be cleared safely.
var _status_owner := ""
## What the work-tile indicator is currently showing ("" = nothing).
var _work_marker_key := ""
var _players: Array[AudioStreamPlayer] = []
var _player_index := 0
var _streams: Dictionary = {}


## The work-tile indicator, the detail card and the order countdowns need
## per-frame attention; each early-outs when nothing about it has changed. While
## the menu is up the attract loop also runs here.
func _process(delta: float) -> void:
	if not _started:
		_attract(delta)
	_update_work_markers()
	_update_detail()
	_update_order_timers()


## How long each order has left before it costs the day. The limit lives on the
## day controller; the clock is the simulation tick. The number is the loudest
## thing on the card and turns red in the last quarter of the window.
func _update_order_timers() -> void:
	if service == null or day == null or _card_timers.is_empty():
		return
	var limit := float(day.order_time_limit_ticks)
	var tps := maxf(float(service.ticks_per_second), 1.0)
	for order in service.orders.active_orders():
		var label := _card_timers.get(order.id) as Label
		if label == null or not is_instance_valid(label):
			continue
		var left := limit - float(service.tick - order.created_tick)
		var seconds := maxi(int(ceil(left / tps)), 0)
		var angry := left < limit * 0.25
		label.text = "%ds" % seconds
		label.add_theme_color_override("font_color",
			Color(1.0, 0.35, 0.3) if angry else Color(0.75, 0.82, 0.92))
		var caption := _card_captions.get(order.id) as Label
		if caption != null and is_instance_valid(caption):
			caption.add_theme_color_override("font_color",
				Color(1.0, 0.5, 0.45) if angry else Color(0.62, 0.68, 0.78))


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
	if intro == null:
		intro = get_node_or_null("Intro") as IntroSequence
	if world == null:
		world = get_node_or_null("../World") as SubViewport

	_build_backdrop()
	_build_frame()
	_build_top_bar()
	_build_order_panel()
	_build_catalog()
	_build_summary()
	_build_menu()
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
		kitchen.layout_rebuilt.connect(_on_layout_rebuilt)
	if placer != null:
		placer.selection_changed.connect(_on_placer_selection)
	if paint != null:
		paint.hint.connect(_on_hint)
	_refresh_money()
	_on_phase(day.phase if day != null else DayController.Phase.BUILD)
	# The menu's showreel needs a kitchen that can cook: lend the shipped venue
	# the pieces it is missing (taken back by start_game).
	if not _started:
		if FileAccess.file_exists(MENU_LAYOUT):
			kitchen.load_layout(MENU_LAYOUT)
		_ensure_attract_stock()
		_attract_clock = 0.0
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


## Keyboard events arrive in the main viewport, but the 3D controllers live
## inside the World SubViewport (rotate, Esc, the map editor's tool keys), so
## they have to be forwarded by hand. Mouse input keeps using the frame's
## gui_input path, which already handles UI consumption.
func _input(event: InputEvent) -> void:
	if world == null or not (event is InputEventKey):
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is SpinBox:
		return  # typing in the designer's map name field
	# A copy: pushing the original marks it handled, which would stop the dev
	# keys (M for the level designer, F1 for the overlay) from ever arriving.
	world.push_input(event.duplicate(), true)


func _on_frame_input(event: InputEvent) -> void:
	if world == null:
		return
	# _gui_input positions are already relative to this control, which matches
	# the viewport's coordinate space 1:1.
	# A copy: pushing the original marks it handled, which would stop the dev
	# keys (M for the level designer, F1 for the overlay) from ever arriving.
	world.push_input(event.duplicate(), true)


func _build_top_bar() -> void:
	var bar := PanelContainer.new()
	bar.name = "TopBar"
	bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	# Wide enough for a full "your kitchen can't make X — you need a Y" line.
	bar.offset_left = -780.0
	bar.offset_top = 10.0
	bar.offset_right = -12.0
	bar.offset_bottom = 84.0
	bar.add_theme_stylebox_override("panel", _panel_style())
	add_child(bar)
	_top_bar = bar
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	bar.add_child(row)
	_money_label = Label.new()
	_money_label.add_theme_font_size_override("font_size", 22)
	row.add_child(_money_label)
	_day_label = Label.new()
	_day_label.add_theme_font_size_override("font_size", 18)
	row.add_child(_day_label)
	_reason_label = Label.new()
	_reason_label.add_theme_font_size_override("font_size", 13)
	_reason_label.add_theme_color_override("font_color", Color(1.0, 0.7, 0.45))
	_reason_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_reason_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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
	_tabs.clear()
	# All first, then the gameplay groupings in catalog order: what holds
	# ingredients, what runs recipes, who does the work.
	var categories: Array[StringName] = [&""]
	for category in FurnitureCatalog.shop_categories():
		categories.append(category)
	for category in categories:
		var tab := Button.new()
		tab.text = "All" if category == &"" else FurnitureCatalog.category_label(category)
		tab.toggle_mode = true
		tab.focus_mode = Control.FOCUS_NONE
		tab.button_group = _tab_group
		tab.button_pressed = category == &""
		tab.custom_minimum_size = Vector2(96, 26)
		tab.add_theme_font_size_override("font_size", 13)
		tab.set_meta("category", category)
		tab.pressed.connect(_on_tab_pressed.bind(category))
		header.add_child(tab)
		_tabs.append(tab)
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
	# The isometric renders are tall (the fridge is 72x147): without
	# EXPAND_IGNORE_SIZE the texture's own height becomes the row's minimum and
	# pushes the description out of the card.
	_detail_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_detail_icon.custom_minimum_size = Vector2(52, 64)
	_detail_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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
		button.focus_mode = Control.FOCUS_NONE
		button.set_meta("cost", def.cost)
		button.set_meta("id", def.id)
		button.pressed.connect(_on_catalog_pressed.bind(def.id))
		_catalog_grid.add_child(button)
	_refresh_money()
	_update_detail()


func _on_tab_pressed(category: StringName) -> void:
	_rebuild_shop(category)
	_play(CLICK_SOUND)


## The detail card describes what the player is looking at, in this order: the
## piece in hand, the placed piece under the cursor, the shop selection. The
## hover fields are the placer's own, so the card and the work-tile indicator
## can never disagree about which piece is being pointed at.
func _update_detail() -> void:
	if _catalog_panel == null or not _catalog_panel.visible:
		return
	var def: FurnitureDef = null
	var inst: FurnitureInstance = null
	var mode := "none"
	if placer != null:
		if placer._grabbed != null:
			inst = placer._grabbed
			mode = "grab"
		elif placer._has_hover and kitchen != null:
			inst = kitchen.furniture_at(placer._hover_cell)
			if inst != null:
				mode = "hover"
		if inst == null and placer.has_selection and placer.current_def() != null:
			def = placer.current_def()
			mode = "select"
	if inst != null:
		def = inst.def
	var key := "%s:%s" % [mode, def.id if def != null else ""]
	if key == _detail_key:
		return
	_detail_key = key
	if def == null:
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
	match mode:
		"grab":
			lines.append("LMB drop it here   RMB put it back")
		"hover":
			lines.append("LMB pick up   RMB sell")
		_:
			lines.append("LMB place   R rotate")
			lines.append("RMB sell   (full price back)")
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
	next.name = "NextDay"
	next.text = "Next day"
	next.custom_minimum_size = Vector2(200, 48)
	next.pressed.connect(_on_next_day_pressed)
	column.add_child(next)
	_summary_button = next


## The main menu: a title card over the live kitchen, shown until Start is
## pressed. Everything else (shop, orders, top bar, placer) stays hidden behind
## [method _apply_menu_gate].
func _build_menu() -> void:
	_menu = PanelContainer.new()
	_menu.name = "Menu"
	# Bottom-anchored: the kitchen (and its chibis) stays visible above the card.
	_menu.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_menu.offset_left = -330.0
	_menu.offset_top = -318.0
	_menu.offset_right = 330.0
	_menu.offset_bottom = -26.0
	_menu.add_theme_stylebox_override("panel", _menu_style())
	add_child(_menu)
	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 14)
	_menu.add_child(column)
	var title := Label.new()
	title.name = "Title"
	title.text = menu_title
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 34)
	column.add_child(title)
	var premise := Label.new()
	premise.name = "Premise"
	premise.text = menu_premise
	premise.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	premise.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	premise.add_theme_font_size_override("font_size", 17)
	premise.add_theme_color_override("font_color", Color(0.84, 0.87, 0.94))
	column.add_child(premise)
	var start := Button.new()
	start.name = "Start"
	start.text = "Start"
	start.custom_minimum_size = Vector2(220, 54)
	start.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	start.add_theme_font_size_override("font_size", 22)
	start.pressed.connect(_on_menu_start_pressed)
	column.add_child(start)
	var controls := Label.new()
	controls.name = "Controls"
	controls.text = menu_controls
	controls.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	controls.add_theme_font_size_override("font_size", 14)
	controls.add_theme_color_override("font_color", Color(0.72, 0.78, 0.88))
	column.add_child(controls)
	var credit := Label.new()
	credit.name = "Credit"
	credit.text = menu_credit
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	credit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	credit.add_theme_font_size_override("font_size", 12)
	credit.add_theme_color_override("font_color", Color(0.55, 0.6, 0.7))
	column.add_child(credit)


func _on_menu_start_pressed() -> void:
	_play(CLICK_SOUND)
	start_game(false)


# ---------------------------------------------------------------------------
# Main menu: attract loop, start and the lent kitchen pieces
# ---------------------------------------------------------------------------

## True once the player has pressed Start (the capture tool reads this).
func is_started() -> bool:
	return _started


## Leaves the main menu: hides the title card, gives the kitchen back to the
## player and — unless [param skip_intro] is set (tests, screenshots) — plays
## the intro sequence. While the intro runs the gameplay UI stays out of the
## frame; it is handed over when the sequence ends or is skipped.
func start_game(skip_intro := false) -> void:
	if _started:
		return
	_started = true
	_menu.visible = false
	_stop_attract()
	# Leave the showreel map: the game starts on the venue the author shipped.
	if kitchen != null and kitchen.layout_file == MENU_LAYOUT:
		kitchen.load_layout("res://resources/layouts/start_kitchen.txt")
	if skip_intro or intro == null:
		_restore_game_ui()
		return
	_hide_gameplay_ui()
	intro.finished.connect(_on_intro_finished, CONNECT_ONE_SHOT)
	intro.play()


func _on_intro_finished() -> void:
	_restore_game_ui()


## The phase UI for the current phase, with the top bar and the placer back.
func _restore_game_ui() -> void:
	_top_bar.visible = true
	_on_phase(day.phase if day != null else DayController.Phase.BUILD)
	_refresh_money()


## The attract loop: while the menu is up the kitchen keeps cooking real orders,
## never more than [member attract_max_pending] pending at once, so the loss
## rule (which counts pending orders) can never fire behind the menu.
func _attract(delta: float) -> void:
	if service == null or day == null or day.phase != DayController.Phase.BUILD:
		return
	_attract_clock -= delta
	if _attract_clock > 0.0:
		return
	_attract_clock = maxf(attract_interval, 0.1)
	_attract_step()


## One attract beat: ask for a real order the kitchen can actually serve. The
## capture tool calls this directly for its menu screenshot.
func _attract_step() -> void:
	if service == null:
		return
	if service.orders.active_orders().size() >= attract_max_pending:
		return
	service.request_order(_attract_dish())


## The next showreel dish: the day's menu, filtered to what this kitchen can
## serve right now, cycled so the menu has some variety.
func _attract_dish() -> StringName:
	var options: Array[StringName] = []
	if service != null and day != null:
		for dish: StringName in day.menu:
			if service.can_serve(dish, [], []).is_empty():
				options.append(dish)
	if options.is_empty():
		return &"burger"
	_attract_dish_index = (_attract_dish_index + 1) % options.size()
	return options[_attract_dish_index]


## Hands the kitchen over: the lent pieces go back, the showreel's orders are
## cleared and the purse is reset, so the demo starts exactly as authored.
func _stop_attract() -> void:
	_clear_attract_stock()
	if service == null:
		return
	for order in service.orders.active_orders():
		service.orders.fail(order, "the menu closed")
		service.board.cancel_for_order(order)
	service.reset_after_day()
	if day != null:
		service.orders.money = day.starting_money


## Lends the kitchen the pieces it needs to cook: the shipped venue has no
## storage and no sink (that is the day-1 lesson), so without this the showreel
## behind the menu would have nothing to do. Lent pieces are never paid for and
## never written into the map (record is false); [method start_game] takes them
## back. Calling it twice on the same map lends nothing twice — worker posts are
## not stations, so the tag check above cannot see them.
func _ensure_attract_stock() -> void:
	if kitchen == null or service == null or kitchen.data == null:
		return
	# The station list must match the layout we are looking at (a map load may
	# have replaced it since the last rebuild).
	service.rebuild_stations()
	for id: StringName in attract_stock:
		var def := FurnitureCatalog.find(id)
		if def == null or _def_tag_present(def) or _attract_lent(id):
			continue
		_place_attract_piece(def)
	if not _attract_pieces.is_empty():
		service.rebuild_stations()


## True when the showreel already lent a piece of this kind.
func _attract_lent(id: StringName) -> bool:
	for inst in _attract_pieces:
		if is_instance_valid(inst) and inst.def != null and inst.def.id == id:
			return true
	return false


## True when the kitchen already has a station carrying any of the piece's tags
## (so a kitchen with storage is not lent a shelf as well).
func _def_tag_present(def: FurnitureDef) -> bool:
	for tag: StringName in def.tags:
		for station in service.stations:
			if station.has_tag(tag):
				return true
	return false


func _place_attract_piece(def: FurnitureDef) -> void:
	var cell := _find_attract_cell(def)
	if cell == ATTRACT_NO_CELL:
		return
	var inst := kitchen.place_furniture(def, cell, 0, {}, false)
	if inst != null:
		_attract_pieces.append(inst)


## Somewhere sensible for a lent piece: the corner of the room farthest from the
## cooking line, clustering with the other lent pieces. Cells beside a station are
## refused outright — a lent fridge parked on the stove's stand tile is what made
## the showreel unable to finish a patty.
func _find_attract_cell(def: FurnitureDef) -> Vector2i:
	if kitchen.data == null:
		return ATTRACT_NO_CELL
	var bounds := kitchen.data.floor_bounds()
	var focus := _cooking_cell()
	var best := ATTRACT_NO_CELL
	var best_score := -(1 << 30)
	var fallback := ATTRACT_NO_CELL
	for z in range(bounds.position.y, bounds.end.y):
		for x in range(bounds.position.x, bounds.end.x):
			var cell := Vector2i(x, z)
			if not kitchen.can_place(def, cell, 0):
				continue
			if _beside_a_station(cell):
				continue
			if fallback == ATTRACT_NO_CELL:
				fallback = cell
			# Farthest from the cooking line, and next to what is already lent.
			var score := absi(cell.x - focus.x) + absi(cell.y - focus.y) * 2
			if _touches_attract_stock(cell):
				score += 1000
			if score > best_score:
				best_score = score
				best = cell
	return best if best != ATTRACT_NO_CELL else fallback


## True when a cell borders any station (or a piece on a station's cell), which
## is exactly where a worker needs to stand to use it.
func _beside_a_station(cell: Vector2i) -> bool:
	if service == null:
		return false
	for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var neighbour: Vector2i = cell + offset
		for station in service.stations:
			if station.cells.has(neighbour):
				return true
	return false


## True when a cell touches a piece this loop has already lent.
func _touches_attract_stock(cell: Vector2i) -> bool:
	for inst in _attract_pieces:
		if not is_instance_valid(inst):
			continue
		if inst.anchor.distance_squared_to(cell) <= 2:
			return true
	return false


func _touches_furniture(cell: Vector2i) -> bool:
	for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		if kitchen.furniture_at(cell + offset) != null:
			return true
	return false


func _cooking_cell() -> Vector2i:
	if service != null:
		for station in service.stations:
			if station.has_tag(&"cooking") and not station.cells.is_empty():
				return station.cells[0]
	if kitchen != null:
		var bounds := kitchen.get_world_bounds()
		if bounds.size != Vector2.ZERO:
			return Vector2i(roundi(bounds.get_center().x), roundi(bounds.get_center().y))
	return Vector2i.ZERO


func _clear_attract_stock() -> void:
	var removed := false
	if kitchen != null:
		for inst in _attract_pieces:
			if is_instance_valid(inst):
				kitchen.remove_furniture(inst, false)
				removed = true
	_attract_pieces.clear()
	if removed and service != null:
		service.rebuild_stations()


## A map load / the capture's layout override replaces every furniture instance,
## lent pieces included: drop the stale references and re-stock if the new map
## still cannot cook.
func _on_layout_rebuilt() -> void:
	_attract_pieces.clear()
	if not _started:
		_ensure_attract_stock()


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

## While the menu is up it owns the screen: the shop, the order panel, the top
## bar and the summary are hidden and the placer stands down.
func _apply_menu_gate() -> void:
	_menu.visible = true
	_hide_gameplay_ui()
	if camera_rig != null:
		camera_rig.set_distance(MENU_DISTANCE)


## Hides everything that belongs to a running game (menu, intro and horror
## cutscenes all want the kitchen alone on screen).
func _hide_gameplay_ui() -> void:
	_top_bar.visible = false
	_catalog_panel.visible = false
	_order_panel.visible = false
	_summary.visible = false
	_backdrop.visible = false
	if placer != null:
		placer.set_enabled(false)
	if kitchen != null:
		kitchen.set_work_markers([], false)


func _on_phase(phase: int) -> void:
	match phase:
		DayController.Phase.BUILD:
			_tween_frame(1.0, 0.0, 0.0, CORNER_RADIUS, 0.0)
			_backdrop.visible = false
			_catalog_panel.visible = true
			_order_panel.visible = false
			if kitchen != null:
				kitchen.set_all_zone_markers(true)
			_summary.visible = false
			_start_button.visible = true
			_day_label.text = "Day %d — build" % (day.day + 1 if day != null else 1)
			_play_music(MUSIC_BUILD, 1.2)
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
			if kitchen != null:
				kitchen.set_all_zone_markers(false)
				kitchen.set_work_markers([], false)
			_summary.visible = false
			_start_button.visible = false
			_clear_cards()
			if day != null:
				_day_label.text = "Day %d — service" % day.day
			_play_music(MUSIC_DAY, 1.2)
			if camera_rig != null:
				camera_rig.set_distance(DAY_DISTANCE)
			if placer != null:
				placer.set_enabled(false)
			_play(DAY_SOUND)
		DayController.Phase.SUMMARY:
			# A lost day's ending owns the screen: its cards follow the horror,
			# and the summary card would offer a continue button mid-cutscene.
			_summary.visible = not _is_run_ending()
			_play(DONE_SOUND)
	if not _started:
		_apply_menu_gate()


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
	_card_timers.erase(order.id)
	_card_captions.erase(order.id)
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
	_card_timers.clear()
	_card_captions.clear()


func _add_card(order: Order) -> void:
	var wrap := Control.new()
	wrap.custom_minimum_size = Vector2(0, 104)
	_order_list.add_child(wrap)
	var card := PanelContainer.new()
	card.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.add_theme_stylebox_override("panel", _card_style())
	wrap.add_child(card)
	# A card can be taller than the 104 px default (an order with modifiers): the
	# wrap has to reserve what the card really needs or the cards overlap.
	card.visible = false  # no half-built card in a frame
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
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	info.add_child(header)
	var title := Label.new()
	title.name = "Dish"
	title.text = order.dish_name
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	title.add_theme_font_size_override("font_size", 17)
	header.add_child(title)
	# The countdown is the loudest thing on the card: a plain-language caption
	# over a number several times the size of the dish name.
	var clock := VBoxContainer.new()
	clock.name = "Clock"
	clock.alignment = BoxContainer.ALIGNMENT_CENTER
	clock.add_theme_constant_override("separation", 0)
	header.add_child(clock)
	var caption := Label.new()
	caption.name = "AngryIn"
	caption.text = "angry in"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	caption.add_theme_font_size_override("font_size", 12)
	caption.add_theme_color_override("font_color", Color(0.62, 0.68, 0.78))
	clock.add_child(caption)
	var timer := Label.new()
	timer.name = "Timer"
	timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	timer.add_theme_font_size_override("font_size", 34)
	clock.add_child(timer)
	_card_timers[order.id] = timer
	_card_captions[order.id] = caption
	for id: StringName in order.adds:
		info.add_child(_modifier_row(id))
	for id: StringName in order.removes:
		info.add_child(_modifier_row(id))
	_cards[order.id] = wrap
	var height := maxf(104.0, card.get_combined_minimum_size().y)
	wrap.custom_minimum_size = Vector2(0, height)
	card.visible = true
	# Slide down from above the panel by moving both vertical offsets together.
	# Never `position` here: the wrap has not been laid out yet, so setting a
	# position would bake a horizontal offset into the card — it would end up
	# wider than the order panel and push its countdown off the screen.
	card.offset_top = -height
	card.offset_bottom = -height
	card.modulate.a = 0.0
	var tween := create_tween().set_parallel()
	tween.tween_property(card, "offset_top", 0.0, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "offset_bottom", 0.0, 0.4).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
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
	if day != null and day.run_over:
		get_tree().reload_current_scene()
		return
	if day != null:
		day.finish_day()


## While a piece that workers can operate is hovered (or dragged), show the
## tiles they can stand on to work it.
func _update_work_markers() -> void:
	if kitchen == null or placer == null or service == null or day == null:
		return
	if day.phase != DayController.Phase.BUILD:
		return
	# Three cases: dragging a placed piece, holding a new one from the shop, or
	# hovering a placed piece. The first two preview the tiles at the spot the
	# piece would land, so the indicator travels with it.
	var inst: FurnitureInstance = null
	var preview_def: FurnitureDef = null
	var key := ""
	if placer._grabbed != null:
		inst = placer._grabbed
		preview_def = inst.def
		key = "grab:%d:%d,%d:%d" % [inst.get_instance_id(), placer._hover_cell.x,
			placer._hover_cell.y, placer.rot_steps]
	elif placer.has_selection and placer.current_def() != null and placer._has_hover:
		preview_def = placer.current_def()
		key = "ghost:%s:%d,%d:%d" % [preview_def.id, placer._hover_cell.x,
			placer._hover_cell.y, placer.rot_steps]
	elif placer._has_hover:
		inst = kitchen.furniture_at(placer._hover_cell)
		if inst != null:
			key = "hover:%d" % inst.get_instance_id()
	if key == _work_marker_key:
		return
	_work_marker_key = key
	var cells: Array[Vector2i] = []
	if preview_def != null:
		cells = service.preview_work_tiles(preview_def, placer._hover_cell, placer.rot_steps)
	elif inst != null:
		var station := _station_for(inst)
		if station != null:
			cells = station.work_tiles
	kitchen.set_work_markers(cells, not cells.is_empty())


func _station_for(inst: FurnitureInstance) -> StationInstance:
	for station in service.stations:
		if station.def == inst.def and station.cells.has(inst.anchor):
			return station
	return null


func _on_placer_selection(_text: String) -> void:
	_update_detail()


func _on_hint(text: String) -> void:
	_catalog_status.text = text
	_status_owner = "hint"


func _on_day_finished(summary: Dictionary) -> void:
	var tail := ""
	if bool(summary.get("run_over", false)):
		tail = "\n\nTHE RESTAURANT IS CLOSED\nNot enough money to rehire the staff ($%d)." % int(summary.get("rehire_fee", 0))
	elif bool(summary.get("lost", false)):
		tail = "\n" + str(summary.get("reason", ""))
		if int(summary.get("eaten", 0)) > 0:
			tail += "\n%d workers eaten — rehiring them costs $%d." % [
				int(summary.get("eaten", 0)), int(summary.get("rehire_fee", 0))]
	elif day != null:
		tail = "\n" + day.next_day_hint()
	_summary_label.text = "Day %d %s\n\nOrders served: %d\nMoney: $%d%s" % [
		int(summary.get("day", 0)),
		"LOST" if summary.get("lost", false) else "complete",
		int(summary.get("served", 0)),
		int(summary.get("money", 0)),
		tail]
	var next_button := _summary_button
	if next_button != null:
		next_button.text = "Start over" if bool(summary.get("run_over", false)) else "Next day"
	if not _is_run_ending():
		# A won day (or the restaurant closing for good): the summary card is the
		# screen, exactly as before.
		_summary.visible = true
	elif _horror_running:
		# The horror chain is still on screen (the chase, the pan back): hand it
		# the numbers, and it plays the cards itself once the mob is done.
		_horror_summary = summary
		_horror_summary_ready = true
	else:
		# A lost day with no mob to wait for (no windows, or horror off): the
		# same ending, minus the chase.
		_play_ending(summary)


## True while the day that just finished ends the run: a lost day plays the
## ending cards and then returns to the main menu, so nothing may offer a
## continue button on top of that (see [method _run_ending]). A won day — and
## the restaurant-closed summary — keep the old next-day flow.
func _is_run_ending() -> bool:
	return day != null and day.lost and not day.run_over


# ---------------------------------------------------------------------------
# The horror cutscene and the end of the run
# ---------------------------------------------------------------------------

## The mob is inside: letterbox in, slow motion, watch it happen. The chase, the
## DAY LOST card, the farewell card and the return to the menu are one
## coroutine, locked by [member _ending_busy] for its whole length, so no second
## card can start on top of this one.
func _on_mob_started(edges: Array) -> void:
	if cutscene == null or _horror_running or _ending_busy:
		return
	_horror_running = true
	_ending_busy = true
	_horror_summary = {}
	_horror_summary_ready = false
	_catalog_panel.visible = false
	_order_panel.visible = false
	_start_button.visible = false
	cutscene.begin()
	cutscene.set_slow_motion(service, HORROR_SLOW_MOTION)
	_play_music(MUSIC_HORROR, 0.4)
	_play(GLASS_SOUND, -6.0)
	await cutscene.letterbox(true, 0.4)
	if not edges.is_empty():
		var edge: Vector3i = edges[0]
		await cutscene.focus_cell(Vector2i(edge.x, edge.y), 9.5, 0.9)
	await cutscene.vignette(0.55, 1.0)
	await cutscene.shake(0.12, 0.35)
	if not service.customers.is_empty():
		await cutscene.follow(service.customers[0], 0.6)
	# Let the chase play out (skippable), then hold on the empty kitchen.
	while service != null and service.mob_active and cutscene != null \
			and not cutscene.skip_requested():
		await get_tree().create_timer(0.15).timeout
	if cutscene == null:
		_horror_running = false
		_ending_busy = false
		return
	# The mob may have finished off the staff: always pan back to the room so the
	# player sees the aftermath instead of a wall.
	cutscene.release_follow()
	var look_at := Vector2i(6, 5)
	if kitchen != null:
		var bounds := kitchen.get_world_bounds()
		if bounds.size != Vector2.ZERO:
			look_at = Vector2i(roundi(bounds.get_center().x), roundi(bounds.get_center().y))
	await cutscene.focus_cell(look_at, 15.0, 1.0)
	# The day closes behind the horror (the controller emits the summary once the
	# kitchen is empty): the cards can only report it once it is in.
	await _await_horror_summary()
	await _run_ending(_horror_summary)
	_horror_running = false
	_ending_busy = false


## A lost day whose mob never made it inside (no windows to break, horror off):
## the same ending cards, on their own. Locked like the horror chain.
func _play_ending(summary: Dictionary) -> void:
	if _ending_busy:
		return
	_ending_busy = true
	if cutscene != null:
		cutscene.begin()
		await _run_ending(summary)
	else:
		# No director to play the cards (a stripped run): the run still ends at
		# the menu, but only after the day controller has closed the day.
		await get_tree().process_frame
		reset_to_menu()
	_ending_busy = false


## The cards of a lost run, one after the other, then the main menu. Only ever
## entered from the ending chain, which owns [member _ending_busy].
func _run_ending(summary: Dictionary) -> void:
	var subtitle := str(summary.get("reason", ""))
	if subtitle.is_empty():
		subtitle = "the kitchen is quiet now"
	await cutscene.title("DAY LOST", subtitle, 2.0)
	await cutscene.shake(0.3, 0.5)
	# The demo's farewell, once: the horror is the ending, and the card says so.
	if not _ending_shown:
		_ending_shown = true
		await cutscene.title(ending_title, ending_subtitle, ending_hold)
	cutscene.set_slow_motion(service, 1.0)
	await cutscene.finish()
	if service != null:
		service.sim_speed = 1.0
	# finish() glides the camera back to the pre-horror framing over its own
	# beat: let it land before the menu applies its own, or the restore wins.
	await cutscene.wait(cutscene.letterbox_duration)
	# The farewell was the last screen: the run is over, back to the menu.
	reset_to_menu()


## Waits for the day controller's summary (it follows the mob once the kitchen is
## empty). The timeout is a safety valve: a lost day must never strand the player
## on a cutscene, so the cards play anyway (only the subtitle is generic then).
func _await_horror_summary(timeout := 30.0) -> void:
	var spent := 0.0
	while not _horror_summary_ready and spent < timeout:
		await get_tree().create_timer(0.05).timeout
		spent += 0.05
		if cutscene != null and cutscene.skip_requested():
			# Skipping the wait sends the mob away; the day then closes on the
			# next tick, exactly like the attack's own timeout.
			if service != null:
				service.stop_mob()


## Back to exactly the state the game boots in: the menu card over the live
## kitchen, the menu map loaded with the pieces the showreel is lent, the day
## counter and the purse at their starting values and the attract loop ready to
## ask for its first order. A lost run ends here; a won day never does (its
## summary keeps the next-day flow).
func reset_to_menu() -> void:
	_started = false
	_horror_running = false
	_ending_busy = false
	_summary.visible = false
	_clear_cards()
	# The menu shows off the venue's menu map — the very one a fresh boot loads.
	if kitchen != null and FileAccess.file_exists(MENU_LAYOUT):
		kitchen.load_layout(MENU_LAYOUT)
	# The run is over: day zero, the purse refilled, the windows repaired, the
	# staff back on shift, no orders or loose items left, and the trays seeded at
	# the new map's intake.
	if day != null:
		day.reset_run()
	# The pieces the showreel needs to cook (start_game takes them back again).
	_ensure_attract_stock()
	_attract_clock = 0.0
	_attract_dish_index = -1
	_apply_menu_gate()


## Dev / capture helper: plays the farewell card on its own (the capture's
## --thanks screenshot). Ignored while an ending sequence is playing.
func play_ending_card() -> void:
	if cutscene == null or _ending_busy:
		return
	_ending_busy = true
	_ending_shown = true
	cutscene.begin()
	await cutscene.title(ending_title, ending_subtitle, ending_hold)
	cutscene.finish()
	_ending_busy = false


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
			_catalog_status.text = "Need $%d more for the %s" % [
				def.cost - service.orders.money, def.display_name]
			_status_owner = "afford"
		elif _status_owner == "afford":
			# Only our own line is cleared; a designer hint keeps its own life.
			_catalog_status.text = ""
			_status_owner = ""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Music lives on the fx scene's audio bank (it may not exist in stripped runs).
func _play_music(track: String, fade := 1.0) -> void:
	var bank := _audio_bank()
	if bank != null and bank.has_method("play_music"):
		bank.call("play_music", track, fade)


func _audio_bank() -> Node:
	if world == null:
		return null
	return world.get_node_or_null("Fx/AudioBank")


func _play(path: String, volume_db := -15.0) -> void:
	if _players.is_empty():
		return
	if not _streams.has(path):
		_streams[path] = load(path)
	var player := _players[_player_index]
	_player_index = (_player_index + 1) % _players.size()
	player.stream = _streams[path]
	player.volume_db = volume_db
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


## The main menu card: darker and roomier than the gameplay panels, so the title
## reads over a busy kitchen.
func _menu_style() -> StyleBoxFlat:
	var style := _panel_style()
	style.bg_color = Color(0.05, 0.06, 0.085, 0.96)
	style.border_color = Color(0.36, 0.42, 0.55, 0.95)
	style.set_corner_radius_all(18)
	style.set_content_margin_all(30)
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
