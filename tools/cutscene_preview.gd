extends Node
## Cutscene preview + verification tool. Instantiates the real demo kitchen in
## a SubViewport, starts day 1 (so the day-phase UI is up), runs a small
## day-loss sequence through [CutsceneDirector] and saves one screenshot per
## beat to /tmp/opencode:
##
##   cutscene_S3_1.png  before anything
##   cutscene_S3_2.png  letterbox bars in + camera focused on a cell
##   cutscene_S3_3.png  title card up
##   cutscene_S3_4.png  vignette + shake (day loss horror beat)
##
## Every beat is checked in the rendered pixels (bars black + correctly sized,
## the focused cell projects to the screen centre, the title is readable, the
## vignette is visible but not opaque). Run with:
##   DISPLAY=:1 godot --path . res://tools/cutscene_preview.tscn
## Exits with code 1 when a check fails.

const OUT_DIR := "/tmp/opencode"
## The delivery pass in the demo kitchen: far enough from the default view
## that the scripted move is obvious, and where trays (and guests) go out.
const FOCUS_CELL := Vector2i(12, 3)
const FOCUS_DISTANCE := 9.0
## Ticks to run past the first arrival so a worker is mid-job and an order
## card is on screen when the cutscene starts.
const TICKS_PAST_FIRST_ARRIVAL := 40

var _sub: SubViewport
var _failures := 0


func _ready() -> void:
	_sub = SubViewport.new()
	_sub.size = Vector2i(1280, 720)
	_sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sub)
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	# Pin the demo layout: main.tscn's own layout is the designer's WIP map, and
	# this preview wants the furnished demo kitchen (workers, stove, assembly).
	var pinned := scene.find_child("Kitchen", true, false) as Kitchen
	if pinned != null:
		pinned.layout_file = "res://resources/layouts/demo_kitchen.txt"
	_sub.add_child(scene)
	await get_tree().process_frame
	var kitchen := scene.find_child("Kitchen", true, false) as Kitchen
	var rig := scene.find_child("CameraRig", true, false) as CameraRig
	var service := scene.find_child("Service", true, false) as Service
	var day := scene.find_child("DayController", true, false) as DayController
	var ui := scene.find_child("UI", true, false) as CanvasLayer
	var world := scene.find_child("World", true, false)
	if kitchen == null or rig == null or service == null:
		print("[preview] FAIL - the demo scene did not load (kitchen=%s rig=%s service=%s)"
			% [kitchen, rig, service])
		get_tree().quit(1)
		return
	_disable_placer(scene)
	_run_into_day(service, day)
	await _settle(6)

	# The director lives where it will in the real game: under the UI CanvasLayer.
	var director := CutsceneDirector.new()
	director.name = "CutsceneDirector"
	if ui != null:
		ui.add_child(director)
	else:
		add_child(director)
	director.setup(rig, world, service)
	var saved_focus := rig._focus
	var saved_distance := rig._target_distance

	# --- beat 1: before ----------------------------------------------------
	var before: Image = await _shot(1)

	# --- beat 2: letterbox in + focus on the assembly table ----------------
	director.begin()
	await director.letterbox(true, 0.5)
	await director.focus_cell(FOCUS_CELL, FOCUS_DISTANCE, 0.9)
	await director.wait(0.2)
	var framed: Image = await _shot(2)
	var focus_offset := _focus_pixel_offset(rig, kitchen)
	_expect(rig._focus.distance_to(saved_focus) > 2.0,
		"focus: the camera really moved (%.1f m)" % rig._focus.distance_to(saved_focus))
	_expect(focus_offset < 40.0,
		"focus: the focused cell projects to the screen centre (off by %.1f px)" % focus_offset)
	_expect(absf(rig._distance - FOCUS_DISTANCE) < 0.6,
		"focus: the camera zoomed to %.1f m (is %.2f m)" % [FOCUS_DISTANCE, rig._distance])

	# --- beat 3: title card ------------------------------------------------
	_beat("title in")
	director.title("DAY LOST", "too many orders — the guests left hungry", 4.0)
	await director.wait(0.8)
	var titled: Image = await _shot(3)
	await director.wait(3.6)
	# Reference for the vignette: same camera, no scrim, no vignette yet.
	_beat("title out, grabbing reference")
	var clear: Image = await _grab()
	_beat("reference grabbed")

	# --- beat 4: vignette + shake -----------------------------------------
	director.vignette(0.9, 0.6)
	director.shake(0.4, 1.4)
	await director.wait(0.5)
	var shake_len := await _wait_for_shake(rig, 0.12)
	var horror: Image = await _shot(4)
	_expect(shake_len > 0.12, "shake: the camera is visibly displaced (%.2f m)" % shake_len)
	var shaken_offset := _focus_pixel_offset(rig, kitchen)
	_expect(shaken_offset > 3.0,
		"shake: the displaced camera moves the rendered frame (focus is %.1f px off centre)" % shaken_offset)

	# --- pixel checks ------------------------------------------------------
	_check_letterbox(before, framed)
	_check_title(framed, titled)
	_check_vignette(clear, horror)
	_expect(_region_diff(clear, horror, 500, 300, 280, 150) > 0.01,
		"shake: the frame content moved between the two shots (%.3f)"
			% _region_diff(clear, horror, 500, 300, 280, 150))
	_expect(_region_lum(framed, 0, 0, framed.get_width(), framed.get_height()) > 0.04,
		"scene: the kitchen is visible under the letterbox")

	# --- finish restores everything ---------------------------------------
	director.finish()
	await director.wait(1.4)
	_expect(not director._top_bar.visible and director._top_bar.offset_bottom == 0.0,
		"finish: the letterbox bars are gone")
	_expect(director._vignette_strength == 0.0, "finish: the vignette is off")
	_expect(rig._focus.distance_to(saved_focus) < 0.5,
		"finish: the camera focus is restored (off by %.2f m)" % rig._focus.distance_to(saved_focus))
	_expect(absf(rig._target_distance - saved_distance) < 0.01, "finish: the zoom is restored")

	await _check_api(service, kitchen)

	print("[preview] day %d phase=%d served=%d lost=%s" % [
		day.day if day != null else -1,
		day.phase if day != null else -1,
		day.served if day != null else -1,
		day.lost if day != null else false])
	print("[preview] %s (%d failures)" % ["FAIL" if _failures > 0 else "ok", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


# ---------------------------------------------------------------------------
# API checks: the parts the day-loss beat does not touch
# ---------------------------------------------------------------------------

## A second director, attached outside the UI and wired by tree search only.
func _check_api(service: Service, kitchen: Kitchen) -> void:
	var director := CutsceneDirector.new()
	director.name = "FallbackDirector"
	add_child(director)
	_expect(director.rig == null and director.service == null, "api: nothing wired up front")
	await director.focus_cell(Vector2i(2, 3), 12.0, 0.05)
	_expect(director.rig != null, "api: the rig is found by tree search when not wired")
	_expect(director.service == service, "api: the service is found by tree search")
	_expect(director.rig._focus.distance_to(kitchen.cell_to_world(Vector2i(2, 3))) < 0.2,
		"api: focus_cell landed on the cell")

	# follow / release
	if not service.workers.is_empty():
		var worker := service.workers[0]
		await director.follow(worker, 0.05)
		_expect(director.rig.follow_target == worker, "api: follow keeps the worker centred")
		await _settle(3)
		_expect(director.rig._target_focus.distance_to(Vector3(
			worker.global_position.x, 0.0, worker.global_position.z)) < 0.2,
			"api: the follow target tracks the worker every frame")
		director.release_follow()
		_expect(director.rig.follow_target == null, "api: release_follow lets go")

	# slow motion is restored by finish, and skip presses are consumed once
	director.begin()
	director.set_slow_motion(service, 0.25)
	_expect(is_equal_approx(service.sim_speed, 0.25), "api: set_slow_motion writes Service.sim_speed")
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.physical_keycode = KEY_ENTER
	director._input(ev)
	_expect(not director.skip_requested(), "api: a press right after begin is ignored")
	await _settle(4)
	director._input(ev)
	_expect(director.skip_requested(), "api: a key press is reported as a skip")
	_expect(not director.skip_requested(), "api: the skip flag is consumed")
	director.request_skip()
	_expect(director.skip_requested(), "api: request_skip works without input")
	_expect(not director.skip_requested(), "api: request_skip is consumed too")
	director.finish()
	_expect(is_equal_approx(service.sim_speed, 0.0), "api: finish restores the previous sim speed")
	director.queue_free()


# ---------------------------------------------------------------------------
# Scene setup
# ---------------------------------------------------------------------------

## Keeps the demo free of placement ghosts (same as the capture tool).
func _disable_placer(scene: Node) -> void:
	var placer := scene.find_child("PlaceController", true, false) as PlaceController
	if placer == null:
		return
	placer.set_process(false)
	placer.set_process_unhandled_input(false)
	for child in placer.get_children():
		if child is Node3D:
			(child as Node3D).visible = false


## Starts day 1 headlessly and steps just past its first arrival, so the day
## phase UI is up, an order card exists and a worker is on a job.
func _run_into_day(service: Service, day: DayController) -> void:
	service.sim_speed = 0.0
	service.orders.arrive_on_turn_in = false
	if day == null:
		return
	var reasons := day.can_start_day()
	print("[preview] gate: ", reasons)
	if not reasons.is_empty():
		return
	day.start_day()
	var first_tick := 0
	if day.plan != null and not day.plan.arrivals.is_empty():
		first_tick = int(day.plan.arrivals[0]["tick"])
	service.run_ticks(first_tick + TICKS_PAST_FIRST_ARRIVAL)
	print("[preview] ran to tick %d: %s" % [service.tick, service.status_text()])


# ---------------------------------------------------------------------------
# Screenshots
# ---------------------------------------------------------------------------

func _shot(index: int) -> Image:
	var image: Image = await _grab()
	var path := "%s/cutscene_S3_%d.png" % [OUT_DIR, index]
	var err := image.save_png(path)
	print("[preview] shot %d -> %s (err=%d)" % [index, path, err])
	_expect(err == OK, "shot %d saved" % index)
	return image


## One frame of the SubViewport, without saving it.
func _grab() -> Image:
	await _settle(3)
	await RenderingServer.frame_post_draw
	return _sub.get_texture().get_image()


func _settle(frames: int) -> void:
	for i in frames:
		await get_tree().process_frame


## Timeline marker (the sequence is real-time, so the log doubles as a script).
func _beat(label: String) -> void:
	print("[preview] t=%.2fs  %s" % [Time.get_ticks_msec() / 1000.0, label])


## Waits (up to a second) for the shake to displace the camera visibly.
func _wait_for_shake(rig: CameraRig, minimum: float) -> float:
	var length := 0.0
	for i in 60:
		length = rig._shake_offset.length()
		if length >= minimum:
			break
		await get_tree().process_frame
	return length


# ---------------------------------------------------------------------------
# Pixel checks
# ---------------------------------------------------------------------------

## Both bars must be black, cover real scene and be the configured height.
func _check_letterbox(before: Image, framed: Image) -> void:
	var w := framed.get_width()
	var h := framed.get_height()
	var bar := int(roundf(float(h) * 0.11))
	_expect(_lum(framed.get_pixel(w / 2, 8)) < 0.02, "letterbox: the top bar is black")
	_expect(_lum(framed.get_pixel(w / 2, h - 8)) < 0.02, "letterbox: the bottom bar is black")
	var was_scene := _lum(before.get_pixel(w / 2, 8))
	_expect(was_scene > 0.05,
		"letterbox: the top bar covers real scene (was %.2f there before)" % was_scene)
	var top := _bar_extent(before, framed, w / 2, true)
	var bottom := _bar_extent(before, framed, w / 2, false)
	_expect(absi(top - bar) <= 10, "letterbox: top bar is %d px (expected ~%d)" % [top, bar])
	_expect(absi(bottom - bar) <= 10, "letterbox: bottom bar is %d px (expected ~%d)" % [bottom, bar])


## A bright title over a darkened scene.
func _check_title(framed: Image, titled: Image) -> void:
	var brightest := 0.0
	for y in range(280, 440, 4):
		for x in range(200, 1080, 4):
			brightest = maxf(brightest, _lum(titled.get_pixel(x, y)))
	_expect(brightest > 0.75, "title: bright text is rendered (max luminance %.2f)" % brightest)
	var before_lum := _lum(framed.get_pixel(150, 300))
	var after_lum := _lum(titled.get_pixel(150, 300))
	_expect(after_lum < before_lum - 0.01,
		"title: the scrim darkens the scene (%.2f -> %.2f)" % [before_lum, after_lum])


## Red/dark edges, untouched centre.
func _check_vignette(titled: Image, horror: Image) -> void:
	var edge_before := _region_lum(titled, 0, 200, 24, 320)
	var edge_after := _region_lum(horror, 0, 200, 24, 320)
	var rg_before := _region_rg(titled, 0, 200, 24, 320)
	var rg_after := _region_rg(horror, 0, 200, 24, 320)
	_expect(edge_after < edge_before - 0.02,
		"vignette: the left edge darkens (%.2f -> %.2f)" % [edge_before, edge_after])
	_expect(rg_after > rg_before + 0.02,
		"vignette: the edge turns red (r-g %.2f -> %.2f)" % [rg_before, rg_after])
	var centre_before := _region_lum(titled, 560, 300, 160, 120)
	var centre_after := _region_lum(horror, 560, 300, 160, 120)
	_expect(centre_after > 0.04, "vignette: the centre is still visible (%.2f)" % centre_after)
	_expect(centre_after > centre_before * 0.5 - 0.02,
		"vignette: the centre is not tinted away (%.2f -> %.2f)" % [centre_before, centre_after])


## How many rows from an edge are black in `framed` but were scene in `before`.
func _bar_extent(before: Image, framed: Image, x: int, from_top: bool) -> int:
	var h := framed.get_height()
	var count := 0
	for i in 240:
		var y := i if from_top else h - 1 - i
		if y < 0 or y >= h:
			break
		if _lum(framed.get_pixel(x, y)) >= 0.02 or _lum(before.get_pixel(x, y)) <= 0.04:
			break
		count = i + 1
	return count


func _focus_pixel_offset(rig: CameraRig, kitchen: Kitchen) -> float:
	var cam := rig.get_node_or_null("Camera3D") as Camera3D
	if cam == null:
		return 9999.0
	# unproject_position is in the camera's own viewport (the World SubViewport,
	# which the day phase resizes), so compare against that centre.
	var screen := cam.unproject_position(kitchen.cell_to_world(FOCUS_CELL))
	var centre := Vector2(cam.get_viewport().get_visible_rect().size) * 0.5
	return screen.distance_to(centre)


func _region_lum(image: Image, x: int, y: int, w: int, h: int) -> float:
	var total := 0.0
	var count := 0
	for py in range(y, mini(y + h, image.get_height())):
		for px in range(x, mini(x + w, image.get_width())):
			total += _lum(image.get_pixel(px, py))
			count += 1
	return total / float(maxi(count, 1))


func _region_rg(image: Image, x: int, y: int, w: int, h: int) -> float:
	var total := 0.0
	var count := 0
	for py in range(y, mini(y + h, image.get_height())):
		for px in range(x, mini(x + w, image.get_width())):
			var c := image.get_pixel(px, py)
			total += c.r - c.g
			count += 1
	return total / float(maxi(count, 1))


## Mean absolute luminance difference between two shots over a region.
func _region_diff(a: Image, b: Image, x: int, y: int, w: int, h: int) -> float:
	var total := 0.0
	var count := 0
	for py in range(y, mini(y + h, mini(a.get_height(), b.get_height()))):
		for px in range(x, mini(x + w, mini(a.get_width(), b.get_width()))):
			total += absf(_lum(a.get_pixel(px, py)) - _lum(b.get_pixel(px, py)))
			count += 1
	return total / float(maxi(count, 1))


func _lum(color: Color) -> float:
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b


func _expect(condition: bool, label: String) -> void:
	if not condition:
		_failures += 1
	print("[preview] %s - %s" % ["ok" if condition else "FAIL", label])
