class_name IntroSequence
extends Node
## The demo's opening, played once when the player leaves the main menu.
##
## A short letterboxed sequence built on [CutsceneDirector]: five cards over the
## live kitchen, two camera beats (the cooking line, then the front door) and a
## single horror hint on "Sales are up" — the lights dip, a low growl and one
## vignette pulse. Any key skips it (the director owns the skip check).
##
## Presentation only (invariant 11): it writes no simulation state at all. The
## only things it touches are the music track, the sun/fill light energies and
## the director's overlays, and all of those are put back in [method _finish].
##
## The copy lives in [member cards] / [member subtitles] so the lines can be
## rewritten from the inspector without touching this script.

@export_group("Wiring")
## Optional explicit wiring; empty paths fall back to a scene search.
@export var cutscene_path: NodePath
@export var kitchen_path: NodePath
@export var service_path: NodePath
## Optional explicit roamers wiring; empty paths fall back to a scene search.
@export var roamers_path: NodePath

@export_group("Copy")
## The card titles, one per beat (five beats in the demo opening).
@export var cards: Array[String] = [
	"You own a franchise.",
	"Then the delivery apps went to war.",
	"Corporate has an idea.",
	"Sales are up.",
	"If the orders pile up, they come inside.",
]
## The line under each card. Keep the same length as [member cards].
@export var subtitles: Array[String] = [
	"Business was fine.",
	"Two of them. They are not named here.",
	"Sell at 99% off. The apps pay the difference.",
	"So is something else.",
	"Serve them. All of them.",
]

@export_group("Timing")
## Seconds each card stays up (the director adds its own fades on top).
@export var card_hold := 2.4
## Seconds a camera beat takes to glide to the next framing.
@export var beat_time := 1.2
## Camera distance on the cooking-line beat (metres).
@export var cooking_distance := 12.5
## Camera distance on the shrine beat (metres). The venue is framed at 15-22 m
## and the camera's FOV is 79 deg wide, so 2 m of display needs a real zoom: at
## this distance the pair fills about half the frame and still reads as a
## display (closer and the plinth leaves the frame).
@export var shrine_distance := 2.8
## Seconds the camera rests on the shrine before card 2 fades in.
@export var shrine_hold := 0.6
## Camera distance on the front-door beat (metres).
@export var door_distance := 11.0
## Seconds the camera rests on the front door before the next card.
@export var door_hold := 1.2
## How long the lights stay dimmed for the horror hint.
@export var dip_time := 1.6
## Light energy multiplier while the hint dims the room (1 = no dip at all).
@export_range(0.0, 1.0, 0.01) var light_dip := 0.35
## Vignette strength of the one hint pulse (0 = no pulse).
@export_range(0.0, 1.0, 0.01) var hint_vignette := 0.5
## How many customers crowd the windows for the card-4 reveal ("so is something
## else"): they are gone again when the sequence ends.
@export var horde_count := 8
## Fixed seed of the reveal horde, so the beat looks the same every run.
@export var horde_seed := 20261031
## Music track id played under the intro (see [constant AudioBank.MUSIC_TRACKS]).
@export var music := "build"

## Emitted when the sequence is over (played through or skipped).
signal finished

## True between [method play] and the end of the sequence.
var running := false
## The card on screen right now (-1 before the first one).
var card_index := -1
## The current beat: "cooking", "shrine", "front_door", "card" or "done". The
## capture tool waits on this to screenshot a specific moment.
var beat := ""
## Anchor cell of the shrine the card-2 beat framed (-1, -1 when the venue has
## none, i.e. the beat was skipped). Tools read this.
var shrine_cell := Vector2i(-1, -1)
## True while the card-4 horde is outside.
var horde_spawned := false

var _director: CutsceneDirector
var _kitchen: Kitchen
var _service: Service
var _roamers: Roamers
var _bank: Node
var _lights: Array[DirectionalLight3D] = []
var _light_base: Array[float] = []
var _light_tween: Tween


# ---------------------------------------------------------------------------
# Sequence
# ---------------------------------------------------------------------------

## Plays the intro: cards, camera beats and the hint, then [signal finished].
## Safe to call once; later calls while [member running] are ignored.
func play() -> void:
	if running:
		return
	running = true
	card_index = -1
	beat = ""
	var director := _cutscene()
	if director == null:
		_finish(null)
		return
	_play_music()
	director.begin()
	# Beat 1: the cooking line, where the showreel was working.
	await director.focus_cell(_cooking_cell(), cooking_distance, beat_time)
	beat = "cooking"
	if director.skip_requested():
		_finish(director)
		return
	# Card 1 over the line.
	if not cards.is_empty():
		if await _card(director, 0):
			_finish(director)
			return
	# Beat 2: the shrine, where the two delivery platforms stand face to face.
	# Card 2 ("then the delivery apps went to war") is read on the close-up.
	if await _shrine_beat(director):
		_finish(director)
		return
	if cards.size() > 1:
		if await _card(director, 1):
			_finish(director)
			return
	# Beat 3: the front door, where the customers will come in. Hold on it for a
	# moment before the card, so the framing reads.
	await director.focus_cell(_front_door_cell(), door_distance, beat_time)
	beat = "front_door"
	await director.wait(door_hold)
	if director.skip_requested():
		_finish(director)
		return
	# Cards 3 to 5. The fourth is the horror: the lights dip, something growls
	# outside, the vignette pulses once and the customers crowd the windows.
	for index in range(2, cards.size()):
		if index == 3:
			_hint()
		if await _card(director, index):
			_finish(director)
			return
	_finish(director)


## Shows one card and waits for it (or for a skip). Returns true when the player
## skipped, so the caller can end the whole sequence.
func _card(director: CutsceneDirector, index: int) -> bool:
	card_index = index
	beat = "card"
	# Fire the director's own title coroutine (fades + hold) and poll the skip
	# flag here: title() cannot cut itself short, but the card must.
	director.title(_card_text(index), _subtitle_text(index), card_hold)
	var total := director.title_fade_in + maxf(card_hold, 0.0) + director.title_fade_out
	var spent := 0.0
	while spent < total:
		if director.skip_requested():
			return true
		await get_tree().create_timer(0.05).timeout
		spent += 0.05
	return false


## The one horror hint: the room darkens, a growl answers from the door, the
## vignette pulses once and — the actual reveal — the customers crowd the windows
## outside. Runs in the background while its card is up.
func _hint() -> void:
	_spawn_horde()
	_dip_lights(true)
	var bank := _audio_bank()
	if bank != null and bank.has_method("play_growl"):
		bank.call("play_growl", _door_position())
	var director := _cutscene()
	if director != null:
		director.vignette(hint_vignette, 0.5)
	await get_tree().create_timer(dip_time).timeout
	_dip_lights(false)
	if director != null:
		director.vignette(0.0, 1.2)


func _finish(director: CutsceneDirector) -> void:
	beat = "done"
	_clear_horde()
	_dip_lights(false)
	if director != null:
		director.finish()
	running = false
	finished.emit()


# ---------------------------------------------------------------------------
# The reveal horde (presentation only, like the roamers themselves)
# ---------------------------------------------------------------------------

## Fills the windows outside with customers for the card-4 beat. A fixed seed, so
## the shot is reproducible, and a guard against the menu: the horde is for the
## intro's beat, never for the showreel behind the title card.
func _spawn_horde() -> void:
	var roamers := _roamers_node()
	if roamers == null or horde_count <= 0:
		return
	var ui := _game_ui()
	if ui != null and ui.has_method("is_started") and not bool(ui.call("is_started")):
		return
	horde_spawned = roamers.start_count(horde_count, horde_seed) > 0
	if horde_spawned:
		roamers.peek_now()


## Clears the horde (the intro ended or was skipped). Only ever touches roamers
## the intro put out itself.
func _clear_horde() -> void:
	if not horde_spawned:
		return
	horde_spawned = false
	var roamers := _roamers_node()
	if roamers != null:
		roamers.stop()


# ---------------------------------------------------------------------------
# Framings
# ---------------------------------------------------------------------------

## Camera beat for card 2: a tight framing of the venue's corporate shrine — the
## two mascots, turned inward, eye to eye. Returns true when the player skipped
## during the beat. A venue without a shrine skips the beat (the card then plays
## over the previous framing), as does a director without a camera.
func _shrine_beat(director: CutsceneDirector) -> bool:
	var shrine := _shrine_instance()
	var rig := director.rig
	if shrine == null or rig == null:
		return false
	beat = "shrine"
	# The rig's zoom limits are tuned for the whole restaurant (6 m minimum); the
	# display is 2 m wide, so this one beat has to get closer than the player
	# ever can. The limit goes back as soon as the camera is in place.
	var saved_min := rig.min_distance
	rig.min_distance = minf(saved_min, shrine_distance)
	await rig.focus_world(shrine.global_position, shrine_distance, beat_time)
	rig.min_distance = saved_min
	await director.wait(shrine_hold)
	return director.skip_requested()


## The venue's corporate shrine, if the map has one: the display the two mascots
## stand on, recognised by the furniture id. Records [member shrine_cell].
func _shrine_instance() -> FurnitureInstance:
	var kitchen := _kitchen_node()
	if kitchen == null:
		return null
	for inst in kitchen.get_furniture_instances():
		if inst.def != null and inst.def.id == &"corporate_shrine":
			shrine_cell = inst.anchor
			return inst
	return null

## The cooking line: the first station that actually cooks, else the map centre.
func _cooking_cell() -> Vector2i:
	var service := _service_node()
	if service != null:
		for station in service.stations:
			if station.has_tag(&"cooking") and not station.cells.is_empty():
				return station.cells[0]
	return _centre_cell()


## The front door: a doorway edge if the map has one, else the delivery point,
## else the map centre. The shipped start map has no doorway, so its "front door"
## is where the orders leave. Doorways on the outer wall are nudged one cell
## inwards so the camera frames the room rather than the void outside it.
func _front_door_cell() -> Vector2i:
	var kitchen := _kitchen_node()
	if kitchen != null and kitchen.data != null:
		for key: Vector3i in kitchen.data.walls:
			if kitchen.data.get_wall_key(key) != KitchenLayout.Wall.DOORWAY:
				continue
			for cell in KitchenLayout.edge_cells(key):
				if not kitchen.has_floor(cell):
					continue
				var centre := _centre_cell()
				var inward := cell + Vector2i(signi(centre.x - cell.x), signi(centre.y - cell.y))
				return inward if kitchen.has_floor(inward) else cell
		for cell: Vector2i in kitchen.data.points:
			if kitchen.data.points[cell] == KitchenLayout.PointKind.DELIVERY:
				return cell
	return _centre_cell()


func _centre_cell() -> Vector2i:
	var kitchen := _kitchen_node()
	if kitchen != null:
		var bounds := kitchen.get_world_bounds()
		if bounds.size != Vector2.ZERO:
			return Vector2i(roundi(bounds.get_center().x), roundi(bounds.get_center().y))
	return Vector2i.ZERO


func _door_position() -> Vector3:
	var kitchen := _kitchen_node()
	if kitchen == null:
		return Vector3(0.0, 1.2, 0.0)
	return kitchen.cell_to_world(_front_door_cell()) + Vector3(0.0, 1.2, 0.0)


# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

func _cutscene() -> CutsceneDirector:
	if _director != null and is_instance_valid(_director):
		return _director
	if not cutscene_path.is_empty():
		_director = get_node_or_null(cutscene_path) as CutsceneDirector
	if _director == null:
		var root := get_tree().current_scene
		if root != null:
			_director = root.find_child("Cutscene", true, false) as CutsceneDirector
	return _director


func _kitchen_node() -> Kitchen:
	if _kitchen != null and is_instance_valid(_kitchen):
		return _kitchen
	if not kitchen_path.is_empty():
		_kitchen = get_node_or_null(kitchen_path) as Kitchen
	if _kitchen == null:
		var director := _cutscene()
		if director != null and director.world != null:
			_kitchen = director.world.get_node_or_null("Kitchen") as Kitchen
	return _kitchen


func _service_node() -> Service:
	if _service != null and is_instance_valid(_service):
		return _service
	if not service_path.is_empty():
		_service = get_node_or_null(service_path) as Service
	if _service == null:
		var director := _cutscene()
		if director != null and director.world != null:
			_service = director.world.get_node_or_null("Service") as Service
	return _service


## The roamers outside the building (main.tscn's World/Roamers); the reveal horde
## is theirs. Presentation only — see [Roamers].
func _roamers_node() -> Roamers:
	if _roamers != null and is_instance_valid(_roamers):
		return _roamers
	if not roamers_path.is_empty():
		_roamers = get_node_or_null(roamers_path) as Roamers
	if _roamers == null:
		var director := _cutscene()
		if director != null and director.world != null:
			_roamers = director.world.get_node_or_null("Roamers") as Roamers
	if _roamers == null:
		var root := get_tree().current_scene
		if root != null:
			_roamers = root.find_child("Roamers", true, false) as Roamers
	return _roamers


## The player UI: whichever ancestor knows whether the menu is still up (the
## intro is a child of it in main.tscn, but the search does not assume that).
func _game_ui() -> Node:
	var node := get_parent()
	while node != null:
		if node.has_method("is_started"):
			return node
		node = node.get_parent()
	return null


func _audio_bank() -> Node:
	if _bank != null and is_instance_valid(_bank):
		return _bank
	var kitchen := _kitchen_node()
	if kitchen != null and kitchen.get_parent() != null:
		_bank = kitchen.get_parent().get_node_or_null("Fx/AudioBank")
	return _bank


func _play_music() -> void:
	var bank := _audio_bank()
	if bank != null and bank.has_method("play_music"):
		bank.call("play_music", music, 1.2)


# ---------------------------------------------------------------------------
# Lights
# ---------------------------------------------------------------------------

## Every directional light in the world (the sun and the fill in main.tscn).
func _world_lights() -> Array[DirectionalLight3D]:
	if not _lights.is_empty():
		return _lights
	var kitchen := _kitchen_node()
	var world: Node = kitchen.get_parent() if kitchen != null else null
	if world == null:
		return _lights
	for node in world.find_children("*", "DirectionalLight3D", true, false):
		var light := node as DirectionalLight3D
		if light != null:
			_lights.append(light)
	return _lights


## Dims or restores the room lights; the base energies are captured on the first
## call and always restored by [method _finish].
func _dip_lights(dim: bool) -> void:
	var lights := _world_lights()
	if lights.is_empty():
		return
	if _light_base.size() != lights.size():
		_light_base.clear()
		for light in lights:
			_light_base.append(light.light_energy)
	if _light_tween != null and _light_tween.is_valid():
		_light_tween.kill()
	_light_tween = create_tween().set_parallel()
	for i in lights.size():
		var light := lights[i]
		if not is_instance_valid(light):
			continue
		var target := _light_base[i]
		if dim:
			target = _light_base[i] * clampf(light_dip, 0.0, 1.0)
		_light_tween.tween_property(light, "light_energy", target, 0.5 if dim else 0.9)


func _card_text(index: int) -> String:
	if index < 0 or index >= cards.size():
		return ""
	return cards[index]


func _subtitle_text(index: int) -> String:
	if index < 0 or index >= subtitles.size():
		return ""
	return subtitles[index]
