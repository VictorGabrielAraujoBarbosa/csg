class_name CameraRig
extends Node3D
## Rotatable 3/4 perspective camera. The rig itself stays at the origin and
## moves its child [Camera3D] around a focus point on the floor.
##
## Besides the player controls, the rig can be driven by [CutsceneDirector]:
## [method focus_cell] / [method focus_world] glide the focus and the distance
## over an exact real-time duration, [method follow] keeps a node centred and
## [method shake] wobbles the view. Scripted moves are pure presentation: they
## only move this node's camera, never the simulation.

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
@export_group("Cutscene")
## Wobbles per second while [method shake] runs. The offset decays linearly
## over the shake's duration.
@export var shake_frequency := 16.0

var bounds := Rect2()

## Node kept centred every frame while set (cutscene follow); null = free camera.
var follow_target: Node3D

var _yaw_deg := 45.0
var _focus := Vector3.ZERO
var _target_focus := Vector3.ZERO
var _distance := 15.0
var _target_distance := 15.0
## True while a scripted move is tweening; player panning is ignored then.
var _scripted := false
var _motion_tween: Tween
var _motion_generation := 0
var _shake_strength := 0.0
var _shake_time := 0.0
var _shake_duration := 0.0
var _shake_offset := Vector3.ZERO
var _shake_generation := 0


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


# ---------------------------------------------------------------------------
# Scripted (cutscene) camera moves — real time only, see CutsceneDirector
# ---------------------------------------------------------------------------

## Glides the focus to a grid cell and zooms to [param distance] metres over
## [param duration] real seconds. Cells are centred at world `(x, 0, z)`
## (grid invariant 1), so no kitchen lookup is needed.
func focus_cell(cell: Vector2i, distance: float, duration := 0.8) -> void:
	await focus_world(Vector3(cell.x, 0.0, cell.y), distance, duration)


## Scripted move to a world position: the focus is flattened onto the floor
## plane and the distance is clamped to the rig's zoom limits.
func focus_world(pos: Vector3, distance: float, duration := 0.8) -> void:
	await _animate_to(Vector3(pos.x, 0.0, pos.z), distance, duration)


## Slides to [param target] over [param duration] and then keeps it centred
## every frame until [method release_follow] (or another scripted move).
func follow(target: Node3D, duration := 0.5) -> void:
	if target == null or camera == null:
		return
	await _animate_to(target.global_position, _target_distance, duration)
	if is_instance_valid(target):
		follow_target = target


func release_follow() -> void:
	follow_target = null


## Real-time camera shake: [param strength] is the offset in metres at the
## start, dying out linearly over [param duration] seconds.
func shake(strength: float, duration: float) -> void:
	_shake_generation += 1
	var gen := _shake_generation
	_shake_strength = strength
	_shake_duration = maxf(duration, 0.001)
	_shake_time = 0.0
	await get_tree().create_timer(_shake_duration).timeout
	if gen == _shake_generation:
		_stop_shake_now()


## Cuts a running shake short.
func stop_shake() -> void:
	_shake_generation += 1
	_stop_shake_now()


func _process(delta: float) -> void:
	if camera == null:
		return
	if follow_target != null:
		if is_instance_valid(follow_target):
			_target_focus = Vector3(follow_target.global_position.x, 0.0, follow_target.global_position.z)
		else:
			follow_target = null
	if not _scripted:
		_process_pan(delta)
	_update_shake(delta)
	var k := 1.0 - exp(-smooth * delta)
	_focus = _focus.lerp(_target_focus, k)
	_distance = lerpf(_distance, _target_distance, k)
	_apply()


func _process_pan(delta: float) -> void:
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
	if pan_right == 0.0 and pan_up == 0.0:
		return
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


## Advances the scripted shake in real time; the offset decays linearly.
func _update_shake(delta: float) -> void:
	if _shake_duration <= 0.0:
		_shake_offset = Vector3.ZERO
		return
	_shake_time += delta
	if _shake_time >= _shake_duration:
		_stop_shake_now()
		return
	var decay := 1.0 - _shake_time / _shake_duration
	var t := _shake_time * shake_frequency
	_shake_offset = Vector3(sin(t), sin(t * 1.37 + 1.7), sin(t * 0.71 + 3.1)) * (_shake_strength * decay)


func _stop_shake_now() -> void:
	_shake_duration = 0.0
	_shake_time = 0.0
	_shake_offset = Vector3.ZERO


## Cancels a scripted move. The awaiting coroutine ends on its own timer and
## only clears the scripted flag if no newer move took over (generation check).
func _stop_motion() -> void:
	if _motion_tween != null and _motion_tween.is_valid():
		_motion_tween.kill()
	_motion_tween = null


## The one place a scripted move happens: tween focus + distance together so
## the duration is exact, and keep the player's panning out of the way.
func _animate_to(focus: Vector3, target_distance: float, duration: float) -> void:
	follow_target = null
	_stop_motion()
	_motion_generation += 1
	var gen := _motion_generation
	var flat := Vector3(focus.x, 0.0, focus.z)
	var dist := clampf(target_distance, min_distance, max_distance)
	_scripted = true
	if duration <= 0.0:
		_focus = flat
		_target_focus = flat
		_distance = dist
		_target_distance = dist
		_scripted = false
		_apply()
		return
	_motion_tween = create_tween().set_parallel()
	_motion_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_motion_tween.tween_property(self, "_focus", flat, duration)
	_motion_tween.tween_property(self, "_target_focus", flat, duration)
	_motion_tween.tween_property(self, "_distance", dist, duration)
	_motion_tween.tween_property(self, "_target_distance", dist, duration)
	await get_tree().create_timer(duration).timeout
	if gen == _motion_generation:
		_scripted = false


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
	camera.global_position = _focus + offset + _shake_offset
	camera.look_at(_focus + _shake_offset, Vector3.UP)


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
