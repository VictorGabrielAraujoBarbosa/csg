class_name AudioBank
extends Node3D
## Pooled positional sound: a small ring of [AudioStreamPlayer3D] plus a couple of
## non-positional UI players, with pitch/volume variation and a master volume.
##
## Purely presentation (invariant 11): nothing here may feed back into the
## simulation. [Vfx] drives it from the simulation's event signals; every
## method is safe to call when the pack is missing (it just does nothing).
##
## Sound -> event mapping (all files ship with the Kenney kits, used as-is):
##   work_started  cook_patty     metalPot1.ogg          pot on the burner
##                 slice_cheese   knifeSlice.ogg         knife on the board
##                 make_salad     chop.ogg
##                 wash           cloth1.ogg             scrubbing
##                 pack_order     cloth3.ogg
##                 burger/serve   impactSoft_medium_000  plating
##                 deliver        impactPlate_light_002  tray over the counter
##                 take_*         metalLatch.ogg         fridge / drawer
##   work_finished cook_patty     metalPot3.ogg          pot off the heat
##                 slice_cheese   knifeSlice2.ogg
##                 make_salad     impactSoft_medium_002
##                 wash           impactPlate_light_003  clean tray down
##                 burger         impactSoft_medium_001
##                 serve          impactPlate_light_000
##                 pack_order     impactPlate_light_001
##                 deliver        confirmation_002.ogg
##                 take_*         metalClick.ogg
##   order_delivered              handleCoins.ogg (3D) + confirmation_004.ogg (UI)
##   item_dropped   trays         impactPlate_light_004  :  impactSoft_medium_003
##   item_carried                 cloth1.ogg (quiet)
##   piece placed                 impactWood_medium_002.ogg
##   window_broken                impactGlass_heavy_000.ogg + creak2.ogg
##   worker_consumed              impactPunch_heavy_002.ogg + cloth4.ogg

const RPG := "res://assets/kenney_rpg-audio/Audio/"
const IMPACT := "res://assets/kenney_impact-sounds/Audio/"
const UI := "res://assets/kenney_interface-sounds/Audio/"

@export var service_path: NodePath
@export var kitchen_path: NodePath

@export_group("Mix")
## Master volume applied on top of every sound (dB).
@export var master_volume_db := -4.0
## Simultaneous 3D sounds (a long day reuses these, nothing is allocated).
@export var pool_size := 12
## Simultaneous non-positional (UI) sounds.
@export var ui_pool_size := 3
## Random pitch spread, as a fraction of 1.0 (0.06 = ±6 %).
@export_range(0.0, 0.5, 0.005) var pitch_variation := 0.06
## Random volume spread on top of the given volume (dB).
@export_range(0.0, 6.0, 0.1) var volume_variation_db := 1.5
## Distance at which a 3D sound is at its loudest (metres).
@export var unit_size := 5.0
## Beyond this distance a 3D sound is silent (metres).
@export var max_distance := 30.0

var service: Service
var kitchen: Kitchen

var _players: Array[AudioStreamPlayer3D] = []
var _ui_players: Array[AudioStreamPlayer] = []
var _next_player := 0
var _next_ui := 0
var _streams: Dictionary = {}   # path -> AudioStream (or null when missing)
var _last_play: Dictionary = {} # throttle key -> msec

## How many sounds actually played (tests / tools read this).
var stats: Dictionary = {}
## How many calls the throttle swallowed.
var throttled: Dictionary = {}


func _ready() -> void:
	service = _resolve_node(service_path, "Service") as Service
	kitchen = _resolve_node(kitchen_path, "Kitchen") as Kitchen
	for i in maxi(pool_size, 1):
		var player := AudioStreamPlayer3D.new()
		player.name = "Sfx%d" % i
		player.unit_size = unit_size
		player.max_distance = max_distance
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(player)
		_players.append(player)
	for i in maxi(ui_pool_size, 1):
		var ui := AudioStreamPlayer.new()
		ui.name = "Ui%d" % i
		add_child(ui)
		_ui_players.append(ui)


func _resolve_node(path: NodePath, name_hint: String) -> Node:
	if not path.is_empty():
		var direct := get_node_or_null(path)
		if direct != null:
			return direct
	for candidate in ["../" + name_hint, "../../" + name_hint, "../../../" + name_hint]:
		var node := get_node_or_null(candidate)
		if node != null:
			return node
	var root := get_tree().current_scene
	if root == null:
		root = get_tree().root
	if root != null:
		return root.find_child(name_hint, true, false)
	return null


# ---------------------------------------------------------------------------
# Core play API
# ---------------------------------------------------------------------------

## Plays [param path] at a world position. Returns the player (or null when the
## file is missing / no player is free).
func play(path: String, position: Vector3, pitch := 1.0, volume_db := 0.0) -> AudioStreamPlayer3D:
	var stream := _stream(path)
	if stream == null:
		return null
	var player := _next_free_3d()
	if player == null:
		return null
	player.stream = stream
	player.global_position = position
	player.pitch_scale = _vary_pitch(pitch)
	player.volume_db = volume_db + master_volume_db + _vary_volume()
	player.play()
	_bump("played")
	return player


## Plays a non-positional sound (menus, jingles). Returns the player or null.
func play_ui(path: String, pitch := 1.0, volume_db := 0.0) -> AudioStreamPlayer:
	var stream := _stream(path)
	if stream == null:
		return null
	var player := _next_free_ui()
	if player == null:
		return null
	player.stream = stream
	player.pitch_scale = _vary_pitch(pitch)
	player.volume_db = volume_db + master_volume_db
	player.play()
	_bump("played_ui")
	return player


## Plays a sound at a grid cell (uses the kitchen's surface height).
func play_cell(path: String, cell: Vector2i, pitch := 1.0, volume_db := 0.0) -> AudioStreamPlayer3D:
	var pos := Vector3(float(cell.x), 0.5, float(cell.y))
	if kitchen != null:
		pos = kitchen.cell_to_world(cell) + Vector3(0.0, kitchen.surface_height(cell), 0.0)
	return play(path, pos, pitch, volume_db)


## Same as [method play], but drops the call when the same key played less than
## [param seconds] ago (ingredient drops must not machine-gun).
func play_throttled(key: String, seconds: float, path: String, position: Vector3,
		pitch := 1.0, volume_db := 0.0) -> AudioStreamPlayer3D:
	var now := Time.get_ticks_msec()
	if now - int(_last_play.get(key, -1000000)) < int(seconds * 1000.0):
		_bump("throttled")
		return null
	_last_play[key] = now
	return play(path, position, pitch, volume_db)


func is_playing() -> bool:
	for player in _players:
		if player.playing:
			return true
	for player in _ui_players:
		if player.playing:
			return true
	return false


## How many pooled players are sounding right now (tests / tools read this).
func playing_count() -> int:
	var count := 0
	for player in _players:
		if player.playing:
			count += 1
	for player in _ui_players:
		if player.playing:
			count += 1
	return count


## The files of every player that is sounding right now (dev tools / tests).
func sounding_paths() -> Array[String]:
	var out: Array[String] = []
	for player in _players:
		if player.playing and player.stream != null:
			out.append(player.stream.resource_path)
	for player in _ui_players:
		if player.playing and player.stream != null:
			out.append(player.stream.resource_path)
	return out


func _next_free_3d() -> AudioStreamPlayer3D:
	for player in _players:
		if not player.playing:
			return player
	if _players.is_empty():
		return null
	# Everything is busy: steal the oldest slot in round-robin order.
	var stolen := _players[_next_player % _players.size()]
	_next_player += 1
	return stolen


func _next_free_ui() -> AudioStreamPlayer:
	for player in _ui_players:
		if not player.playing:
			return player
	if _ui_players.is_empty():
		return null
	var stolen := _ui_players[_next_ui % _ui_players.size()]
	_next_ui += 1
	return stolen


func _stream(path: String) -> AudioStream:
	if _streams.has(path):
		return _streams[path]
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("AudioBank: cannot load '%s'" % path)
	_streams[path] = stream
	return stream


func _vary_pitch(pitch: float) -> float:
	if pitch_variation <= 0.0:
		return pitch
	return pitch * randf_range(1.0 - pitch_variation, 1.0 + pitch_variation)


func _vary_volume() -> float:
	if volume_variation_db <= 0.0:
		return 0.0
	return randf_range(-volume_variation_db, 0.0)


func _bump(key: String) -> void:
	stats[key] = int(stats.get(key, 0)) + 1


# ---------------------------------------------------------------------------
# Named helpers: the game's sound set, keyed by recipe / event
# ---------------------------------------------------------------------------

func play_work_start(recipe_id: StringName, position: Vector3) -> void:
	var recipe := _base_recipe(recipe_id)
	match recipe:
		"cook_patty":
			play(RPG + "metalPot1.ogg", position, 1.0, -5.0)
		"slice_cheese":
			play(RPG + "knifeSlice.ogg", position, 1.0, -4.0)
		"make_salad":
			play(RPG + "chop.ogg", position, 1.0, -4.0)
		"wash":
			play(RPG + "cloth1.ogg", position, 1.0, -8.0)
		"pack_order":
			play(RPG + "cloth3.ogg", position, 1.0, -9.0)
		"burger", "serve":
			play(IMPACT + "impactSoft_medium_000.ogg", position, 1.0, -9.0)
		"deliver":
			play(IMPACT + "impactPlate_light_002.ogg", position, 1.0, -6.0)
		_:
			if recipe.begins_with("take_"):
				play(RPG + "metalLatch.ogg", position, 1.0, -11.0)
			else:
				play(RPG + "cloth1.ogg", position, 1.0, -11.0)


func play_work_finish(recipe_id: StringName, position: Vector3) -> void:
	var recipe := _base_recipe(recipe_id)
	match recipe:
		"cook_patty":
			play(RPG + "metalPot3.ogg", position, 1.0, -4.0)
		"slice_cheese":
			play(RPG + "knifeSlice2.ogg", position, 1.0, -5.0)
		"make_salad":
			play(IMPACT + "impactSoft_medium_002.ogg", position, 1.0, -7.0)
		"wash":
			play(IMPACT + "impactPlate_light_003.ogg", position, 1.0, -5.0)
		"pack_order":
			play(IMPACT + "impactPlate_light_001.ogg", position, 1.0, -7.0)
		"burger":
			play(IMPACT + "impactSoft_medium_001.ogg", position, 1.0, -7.0)
		"serve":
			play(IMPACT + "impactPlate_light_000.ogg", position, 1.0, -7.0)
		"deliver":
			play(UI + "confirmation_002.ogg", position, 1.0, -6.0)
		_:
			if recipe.begins_with("take_"):
				play(RPG + "metalClick.ogg", position, 1.2, -12.0)
			else:
				play(IMPACT + "impactGeneric_light_002.ogg", position, 1.0, -8.0)


## A finished order left the kitchen: coins in the world, a jingle on the UI.
func play_delivered(position: Vector3) -> void:
	play(RPG + "handleCoins.ogg", position, 1.0, -3.0)
	play_ui(UI + "confirmation_004.ogg", 1.0, -4.0)


## A carried item landed. Trays clatter, everything else lands softly.
func play_drop(item_id: StringName, position: Vector3) -> void:
	if String(item_id).begins_with("tray"):
		play_throttled("drop", 0.1, IMPACT + "impactPlate_light_004.ogg", position, 1.1, -9.0)
	else:
		play_throttled("drop", 0.1, IMPACT + "impactSoft_medium_003.ogg", position, 1.0, -12.0)


## A worker lifted an item off a surface.
func play_pickup(position: Vector3) -> void:
	play_throttled("pickup", 0.12, RPG + "cloth1.ogg", position, 1.15, -14.0)


## A piece of furniture landed on the floor.
func play_place(position: Vector3) -> void:
	play_throttled("place", 0.05, IMPACT + "impactWood_medium_002.ogg", position, 1.0, -7.0)


## Horror: a window / wall edge broke open.
func play_window_break(position: Vector3) -> void:
	play(IMPACT + "impactGlass_heavy_000.ogg", position, 1.0, -2.0)
	play(RPG + "creak2.ogg", position, 0.9, -8.0)


## Horror: a worker was eaten.
func play_worker_consumed(position: Vector3) -> void:
	play(IMPACT + "impactPunch_heavy_002.ogg", position, 1.0, -2.0)
	play(RPG + "cloth4.ogg", position, 0.85, -6.0)


## Generic UI confirmation (menus, day start, ...).
func play_confirm() -> void:
	play_ui(UI + "confirmation_001.ogg", 1.0, -5.0)


## "burger__no_cheese" / "serve__burger__none" -> "burger" / "serve".
func _base_recipe(recipe_id: StringName) -> String:
	var text := String(recipe_id)
	var cut := text.find("__")
	return text if cut < 0 else text.substr(0, cut)
