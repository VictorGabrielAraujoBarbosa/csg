class_name CameraRig
extends Node3D
## Rotatable 3/4 perspective camera. The rig itself stays at the origin and
## moves its child [Camera3D] around a focus point on the floor.

@export var camera: Camera3D
@export_group("View")
## Camera pitch in degrees: 90 = straight down, lower = more of a 3D view.
@export var pitch_deg := 50.0
## Yaw of the starting view. 0 is aligned with the grid (looking north).
@export var start_yaw_deg := 0.0
## How much Q/E turns the camera each press.
@export var turn_step_deg := 90.0
## Horizontal field of view (79 matches a 50 degrees vertical view at 16:9).
@export var fov := 79.0
## Keep the horizontal view fixed when the window is tall/narrow (portrait),
## so the camera never "zooms in" on odd window sizes.
@export var keep_width := true
@export_group("Distance")
@export var distance := 15.0
@export var min_distance := 6.0
@export var max_distance := 34.0
@export var zoom_step := 1.5
@export_group("Controls")
@export var pan_speed := 14.0
@export var smooth := 12.0
## How far the camera may pan past the kitchen bounds.
@export var focus_margin := 4.0

var bounds := Rect2()

var _yaw_deg := 45.0
var _focus := Vector3.ZERO
var _target_focus := Vector3.ZERO
var _distance := 15.0
var _target_distance := 15.0


func _ready() -> void:
	if camera == null:
		camera = get_node_or_null("Camera3D") as Camera3D
	if camera == null:
		push_warning("CameraRig: no Camera3D assigned or found")
		return
	_yaw_deg = start_yaw_deg
	_distance = distance
	_target_distance = distance
	_apply()


func focus_on(pos: Vector3) -> void:
	_target_focus = Vector3(pos.x, 0.0, pos.z)
	_focus = _target_focus


func set_bounds(rect: Rect2) -> void:
	bounds = rect.grow(focus_margin)


## Smoothly zooms to a distance (the rig lerps towards it every frame).
func set_distance(new_distance: float) -> void:
	_target_distance = clampf(new_distance, min_distance, max_distance)


func _process(delta: float) -> void:
	if camera == null:
		return
	var pan_right := 0.0
	var pan_up := 0.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		pan_right -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		pan_right += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		pan_up += 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		pan_up -= 1.0
	if pan_right != 0.0 or pan_up != 0.0:
		var basis := camera.global_transform.basis
		var fwd := -basis.z
		fwd.y = 0.0
		var right := basis.x
		right.y = 0.0
		var move := (right * pan_right + fwd.normalized() * pan_up).normalized()
		move *= pan_speed * delta * (_target_distance / distance)
		_target_focus += move
		if bounds.size != Vector2.ZERO:
			_target_focus.x = clampf(_target_focus.x, bounds.position.x, bounds.end.x)
			_target_focus.z = clampf(_target_focus.z, bounds.position.y, bounds.end.y)
	var k := 1.0 - exp(-smooth * delta)
	_focus = _focus.lerp(_target_focus, k)
	_distance = lerpf(_distance, _target_distance, k)
	_apply()


func _apply() -> void:
	if camera == null:
		return
	camera.fov = fov
	camera.keep_aspect = Camera3D.KEEP_WIDTH if keep_width else Camera3D.KEEP_HEIGHT
	var pitch := deg_to_rad(pitch_deg)
	var yaw := deg_to_rad(_yaw_deg)
	var offset := Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)
	) * _distance
	camera.global_position = _focus + offset
	camera.look_at(_focus, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match (event as InputEventKey).physical_keycode:
			KEY_Q:
				_yaw_deg += turn_step_deg
			KEY_E:
				_yaw_deg -= turn_step_deg
	elif event is InputEventMouseButton and event.pressed:
		match (event as InputEventMouseButton).button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_target_distance = clampf(_target_distance - zoom_step, min_distance, max_distance)
			MOUSE_BUTTON_WHEEL_DOWN:
				_target_distance = clampf(_target_distance + zoom_step, min_distance, max_distance)
