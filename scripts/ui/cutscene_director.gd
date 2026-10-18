class_name CutsceneDirector
extends Node
## Reusable director for scripted presentation sequences: letterbox bars, a
## title card, a vignette and the camera beats (focus, follow, shake).
##
## Everything is built in code ([StyleBoxFlat]-free [ColorRect]s + one small
## canvas_item shader) and runs in real time — [Tween]s and
## [method SceneTree.create_timer] — so a cutscene never touches the
## simulation. The only sim state it may write is [member Service.sim_speed]
## (via [method set_slow_motion]), and [method finish] puts that back.
##
## A sequence is a short await-style script:
## [codeblock]
## director.begin()
## await director.focus_cell(Vector2i(9, 7), 12.0, 0.9)
## await director.title("DAY LOST", "too many orders", 2.0)
## director.vignette(0.9, 0.6)
## director.shake(0.35, 1.2)
## await director.wait(1.0)
## director.finish()
## [/codeblock]
##
## Attach it under the UI CanvasLayer (or anywhere else); the wiring falls back
## to the first [CameraRig] / [Service] found in the scene when the exported
## paths are empty. The overlays live in their own high [CanvasLayer] child so
## they always draw above the game UI.

@export_group("Wiring")
## Optional explicit wiring; empty paths fall back to a tree search.
@export var rig_path: NodePath
@export var world_path: NodePath
@export var service_path: NodePath

@export_group("Letterbox")
## Height of each black bar as a fraction of the viewport height.
@export var letterbox_ratio := 0.11
## Seconds the bars take to slide in and out.
@export var letterbox_duration := 0.5

@export_group("Title card")
## Title font size (the Godot default font, as everywhere else in the UI).
@export var title_font_size := 64
## Subtitle font size.
@export var subtitle_font_size := 26
## How dark the screen goes behind a title card (0 = no scrim).
@export var title_scrim_alpha := 0.4
## Seconds the card takes to fade in.
@export var title_fade_in := 0.35
## Seconds the card takes to fade out.
@export var title_fade_out := 0.5

@export_group("Vignette")
## Corner tint; the screen centre stays untouched.
@export var vignette_color := Color(0.33, 0.02, 0.03)
## Alpha at the corners when [method vignette] is called with strength 1.
@export var vignette_max_alpha := 0.65
## How far the darkening reaches inwards (1 = all the way to the centre).
@export var vignette_softness := 0.85

@export_group("Behaviour")
## Put the pre-cutscene camera focus and distance back in [method finish].
@export var restore_camera := true
## Frames after [method begin] during which presses are ignored, so the click
## that started the cutscene cannot also skip it.
@export var skip_grace_frames := 2
## Require Enter (or keypad Enter) to skip, instead of any key or click: a stray
## click while a card is on screen used to cut the sequence short.
@export var skip_requires_enter := true

## True between [method begin] and [method finish].
var active := false

var rig: CameraRig
## Usually the World SubViewport from main.tscn; typed loosely so both a
## SubViewport and a plain Node3D container are accepted.
var world: Node
var service: Service

var _layer: CanvasLayer
var _top_bar: ColorRect
var _bottom_bar: ColorRect
var _title_root: Control
var _title_label: Label
var _subtitle_label: Label
var _scrim: ColorRect
var _vignette: ColorRect
var _vignette_material: ShaderMaterial

var _letterbox_on := false
var _letterbox_tween: Tween
var _title_tween: Tween
var _vignette_tween: Tween
var _title_generation := 0
var _vignette_strength := 0.0

var _saved_focus := Vector3.ZERO
var _saved_distance := 15.0
var _camera_saved := false

var _speed_service: Service
var _saved_sim_speed := 1.0
var _speed_saved := false

var _skip_pressed := false
var _begin_frame := -1000


func _ready() -> void:
	# Only listen for skip presses while a cutscene runs (begin/finish toggle it).
	set_process_input(false)


## Explicit wiring, optional: the director finds these itself when omitted.
## [param new_world] is whatever holds the 3D world (the World SubViewport in
## main.tscn, or any Node3D container).
func setup(new_rig: CameraRig, new_world: Node, new_service: Service) -> void:
	rig = new_rig
	world = new_world
	service = new_service


# ---------------------------------------------------------------------------
# Sequence control
# ---------------------------------------------------------------------------

## Starts a cutscene: slides the letterbox bars in, remembers the camera and
## arms the skip check. Locks nothing by itself — the sequence decides.
func begin() -> void:
	_resolve()
	_ensure_layer()
	if not active:
		_capture_camera()
	active = true
	_skip_pressed = false
	_begin_frame = Engine.get_process_frames()
	set_process_input(true)
	letterbox(true, letterbox_duration)


## Ends a cutscene: bars out, title cleared, vignette faded, follow/shake
## released, the camera restored and [member Service.sim_speed] put back.
func finish() -> void:
	active = false
	_skip_pressed = false
	set_process_input(false)
	release_follow()
	if rig != null:
		rig.stop_shake()
	if _layer != null and is_instance_valid(_layer):
		if _title_root != null:
			_title_generation += 1
			_kill_title_tween()
			_title_root.visible = false
		vignette(0.0, letterbox_duration)
		letterbox(false, letterbox_duration)
	_restore_sim_speed()
	if restore_camera and _camera_saved and rig != null:
		rig.focus_world(_saved_focus, _saved_distance, letterbox_duration)
	_camera_saved = false


## Awaits [param seconds] of real time (the animation clock — never ticks).
func wait(seconds: float) -> void:
	if seconds <= 0.0:
		await get_tree().process_frame
		return
	await get_tree().create_timer(seconds).timeout


## True once since the last call when the player pressed a key or clicked.
## The flag is consumed: every press is reported exactly once.
func skip_requested() -> bool:
	if not _skip_pressed:
		return false
	_skip_pressed = false
	return true


## Records a skip without player input (a skip button, a tool script).
func request_skip() -> void:
	_skip_pressed = true


## Sets [member Service.sim_speed]; [method finish] puts the old value back.
func set_slow_motion(target: Service, speed: float) -> void:
	var svc := target
	if svc == null:
		_resolve()
		svc = service
	if svc == null:
		push_warning("CutsceneDirector: no Service to slow down")
		return
	if not _speed_saved or _speed_service != svc:
		_saved_sim_speed = svc.sim_speed
		_speed_saved = true
	_speed_service = svc
	svc.sim_speed = speed


# ---------------------------------------------------------------------------
# Presentation beats (coroutines unless noted)
# ---------------------------------------------------------------------------

## Slides the two black bars in or out over [param duration] seconds.
func letterbox(on: bool, duration := 0.5) -> void:
	_ensure_layer()
	_letterbox_on = on
	var height := _bar_height() if on else 0.0
	_kill_letterbox_tween()
	if _top_bar == null or _bottom_bar == null:
		return
	_top_bar.visible = on
	_bottom_bar.visible = on
	if duration <= 0.0:
		_apply_letterbox(height)
		return
	_letterbox_tween = create_tween().set_parallel()
	_letterbox_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_letterbox_tween.tween_property(_top_bar, "offset_bottom", height, duration)
	_letterbox_tween.tween_property(_bottom_bar, "offset_top", -height, duration)
	await get_tree().create_timer(duration).timeout


## Camera beat: glides the focus to a grid cell and zooms to [param distance]
## metres over [param duration] real seconds.
func focus_cell(cell: Vector2i, distance: float, duration := 0.8) -> void:
	if not _resolve():
		await wait(duration)
		return
	await rig.focus_cell(cell, distance, duration)


## Camera beat: keeps [param target] centred from now on, after sliding to it.
## Release with [method release_follow] (or any other camera beat).
func follow(target: Node3D, duration := 0.5) -> void:
	if not _resolve():
		return
	await rig.follow(target, duration)


func release_follow() -> void:
	if rig != null:
		rig.release_follow()


## Camera beat: shakes the camera, [param strength] in metres.
func shake(strength: float, duration: float) -> void:
	if not _resolve():
		await wait(duration)
		return
	await rig.shake(strength, duration)


## Fades the red/dark vignette to [param strength] (0 = off, 1 = maximum).
func vignette(strength: float, duration: float) -> void:
	_ensure_layer()
	if _vignette == null:
		return
	_kill_vignette_tween()
	var from := _vignette_strength
	_vignette_strength = clampf(strength, 0.0, 1.0)
	_vignette.visible = _vignette_strength > 0.0 or from > 0.0
	if duration <= 0.0:
		_set_vignette(_vignette_strength)
		_vignette.visible = _vignette_strength > 0.0
		return
	_vignette_tween = create_tween()
	_vignette_tween.set_trans(Tween.TRANS_SINE)
	_vignette_tween.tween_method(_set_vignette, from, _vignette_strength, duration)
	await get_tree().create_timer(duration).timeout
	if _vignette_strength <= 0.0 and _vignette != null:
		_vignette.visible = false


## Shows a centred title card, waits [param hold] seconds and fades it out.
func title(text: String, subtitle := "", hold := 2.0) -> void:
	_ensure_layer()
	if _title_root == null:
		await wait(hold)
		return
	_title_generation += 1
	var gen := _title_generation
	_kill_title_tween()
	_title_label.text = text
	_subtitle_label.text = subtitle
	_subtitle_label.visible = not subtitle.is_empty()
	_title_root.visible = true
	_title_root.modulate.a = 0.0
	_scrim.color = Color(0.0, 0.0, 0.0, 0.0)
	_title_tween = create_tween().set_parallel()
	_title_tween.tween_property(_title_root, "modulate:a", 1.0, title_fade_in)
	_title_tween.tween_property(_scrim, "color:a", title_scrim_alpha, title_fade_in)
	await get_tree().create_timer(title_fade_in + maxf(hold, 0.0)).timeout
	if gen != _title_generation:
		return
	_title_tween = create_tween().set_parallel()
	_title_tween.tween_property(_title_root, "modulate:a", 0.0, title_fade_out)
	_title_tween.tween_property(_scrim, "color:a", 0.0, title_fade_out)
	await get_tree().create_timer(title_fade_out).timeout
	if gen == _title_generation:
		_title_root.visible = false


# ---------------------------------------------------------------------------
# Overlays
# ---------------------------------------------------------------------------

func _ensure_layer() -> void:
	if _layer != null and is_instance_valid(_layer):
		return
	_layer = CanvasLayer.new()
	_layer.name = "CutsceneLayer"
	# Above the game UI (game_ui.gd uses the default layer 1).
	_layer.layer = 100
	add_child(_layer)
	_build_letterbox()
	_build_vignette()
	_build_title()


func _build_letterbox() -> void:
	_top_bar = _make_bar("LetterboxTop", true)
	_bottom_bar = _make_bar("LetterboxBottom", false)


func _make_bar(bar_name: String, at_top: bool) -> ColorRect:
	var bar := ColorRect.new()
	bar.name = bar_name
	bar.color = Color.BLACK
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.anchor_left = 0.0
	bar.anchor_right = 1.0
	bar.anchor_top = 0.0 if at_top else 1.0
	bar.anchor_bottom = bar.anchor_top
	bar.offset_top = 0.0
	bar.offset_bottom = 0.0
	bar.visible = false
	_layer.add_child(bar)
	return bar


func _build_vignette() -> void:
	_vignette = ColorRect.new()
	_vignette.name = "Vignette"
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.color = Color.WHITE
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vignette_material = ShaderMaterial.new()
	_vignette_material.shader = _vignette_shader()
	_vignette_material.set_shader_parameter("strength", 0.0)
	_vignette_material.set_shader_parameter("edge_color", vignette_color)
	_vignette_material.set_shader_parameter("max_alpha", vignette_max_alpha)
	_vignette_material.set_shader_parameter("softness", vignette_softness)
	_vignette.material = _vignette_material
	_vignette.visible = false
	_layer.add_child(_vignette)


func _build_title() -> void:
	_title_root = Control.new()
	_title_root.name = "TitleCard"
	_title_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_root.visible = false
	_layer.add_child(_title_root)
	_scrim = ColorRect.new()
	_scrim.name = "Scrim"
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0.0, 0.0, 0.0, 0.0)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_root.add_child(_scrim)
	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_root.add_child(center)
	var column := VBoxContainer.new()
	column.name = "Column"
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 14)
	center.add_child(column)
	_title_label = Label.new()
	_title_label.name = "Title"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", title_font_size)
	_title_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_title_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	_title_label.add_theme_constant_override("outline_size", 8)
	column.add_child(_title_label)
	_subtitle_label = Label.new()
	_subtitle_label.name = "Subtitle"
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_label.add_theme_font_size_override("font_size", subtitle_font_size)
	_subtitle_label.add_theme_color_override("font_color", Color(0.88, 0.82, 0.8))
	_subtitle_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.8))
	_subtitle_label.add_theme_constant_override("outline_size", 5)
	column.add_child(_subtitle_label)


func _bar_height() -> float:
	var vp := get_viewport()
	if vp == null:
		return 0.0
	return roundf(vp.get_visible_rect().size.y * letterbox_ratio)


func _apply_letterbox(height: float) -> void:
	if _top_bar == null or _bottom_bar == null:
		return
	_top_bar.offset_bottom = height
	_bottom_bar.offset_top = -height


func _set_vignette(value: float) -> void:
	if _vignette_material != null:
		_vignette_material.set_shader_parameter("strength", value)


func _kill_letterbox_tween() -> void:
	if _letterbox_tween != null and _letterbox_tween.is_valid():
		_letterbox_tween.kill()
	_letterbox_tween = null


func _kill_title_tween() -> void:
	if _title_tween != null and _title_tween.is_valid():
		_title_tween.kill()
	_title_tween = null


func _kill_vignette_tween() -> void:
	if _vignette_tween != null and _vignette_tween.is_valid():
		_vignette_tween.kill()
	_vignette_tween = null


func _process(_delta: float) -> void:
	# Keep the bars the right size when the window changes mid-cutscene (but
	# never fight the slide-in tween).
	if _layer == null or not _letterbox_on or _top_bar == null:
		return
	if _letterbox_tween != null and _letterbox_tween.is_valid() and _letterbox_tween.is_running():
		return
	var height := _bar_height()
	if not is_equal_approx(_top_bar.offset_bottom, height):
		_apply_letterbox(height)


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

## Finds the rig/world/service; true when a camera rig is available.
func _resolve() -> bool:
	if rig == null and rig_path != NodePath():
		rig = get_node_or_null(rig_path) as CameraRig
	if world == null and world_path != NodePath():
		world = get_node_or_null(world_path)
	if service == null and service_path != NodePath():
		service = get_node_or_null(service_path) as Service
	if rig != null and world == null:
		world = rig.get_parent()
	var tree := get_tree()
	if tree == null:
		return rig != null
	var root: Node = tree.current_scene
	if root == null:
		root = tree.root
	if rig == null:
		rig = _find_first(root, func(node: Node) -> bool: return node is CameraRig) as CameraRig
	if service == null and world != null:
		service = _find_first(world, func(node: Node) -> bool: return node is Service) as Service
	if service == null:
		service = _find_first(root, func(node: Node) -> bool: return node is Service) as Service
	return rig != null


## Depth-first search for the first descendant matching a predicate.
func _find_first(from: Node, predicate: Callable) -> Node:
	if from == null:
		return null
	for node in from.find_children("*", "", true, false):
		if bool(predicate.call(node)):
			return node
	return null


func _capture_camera() -> void:
	if rig == null:
		_camera_saved = false
		return
	# Same package as the rig: read its live view state directly.
	_saved_focus = rig._focus
	_saved_distance = rig._target_distance
	_camera_saved = true


func _restore_sim_speed() -> void:
	if not _speed_saved:
		return
	if _speed_service != null and is_instance_valid(_speed_service):
		_speed_service.sim_speed = _saved_sim_speed
	_speed_service = null
	_speed_saved = false


func _input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		if skip_requires_enter and key.physical_keycode != KEY_ENTER \
				and key.physical_keycode != KEY_KP_ENTER:
			return
	elif skip_requires_enter:
		# Only Enter skips: a stray click while reading a card should not end it.
		return
	elif event is InputEventMouseButton:
		if not (event as InputEventMouseButton).pressed:
			return
	elif event is InputEventJoypadButton:
		if not (event as InputEventJoypadButton).pressed:
			return
	elif event is InputEventScreenTouch:
		if not (event as InputEventScreenTouch).pressed:
			return
	else:
		return
	if Engine.get_process_frames() - _begin_frame < skip_grace_frames:
		return
	_skip_pressed = true


func _vignette_shader() -> Shader:
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
// Radial darkening for horror beats: nothing at the screen centre, the edge
// colour (semi-transparent) in the corners. `strength` is the fade amount.
uniform float strength : hint_range(0.0, 1.0) = 0.0;
uniform vec4 edge_color : source_color = vec4(0.33, 0.02, 0.03, 1.0);
uniform float max_alpha : hint_range(0.0, 1.0) = 0.65;
uniform float softness : hint_range(0.05, 1.5) = 0.85;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float d = length(p) * 0.70710678;
	float v = smoothstep(1.0 - softness, 1.0, d) * strength;
	COLOR = vec4(edge_color.rgb, v * max_alpha * edge_color.a);
}
"""
	return shader
