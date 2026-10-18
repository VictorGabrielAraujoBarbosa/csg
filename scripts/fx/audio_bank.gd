class_name AudioBank
extends Node3D
## Pooled positional sound: a small ring of [AudioStreamPlayer3D] plus a couple of
## non-positional UI players, with pitch/volume variation and a master volume.
##
## Purely presentation (invariant 11): nothing here may feed back into the
## simulation. [Vfx] drives it from the simulation's event signals; every
## method is safe to call when the pack is missing (it just does nothing).
##
## The bank also owns the sounds that have no event to hang off: footsteps (a
## light per-frame poll of the walkers' cells), the horror bed (panic squeaks,
## growls and the heartbeat pulse that follows [member Service.mob_active]), the
## UI tells and the music player. Nothing here decides *when* music plays: the
## game UI calls [method play_music] / [method stop_music] / [method duck].
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
##   --- polled / called by hand (there is no signal to hang off) --------------
##   a worker crosses a cell      footstep00..09.ogg          [method play_footstep]
##   a customer crosses a cell    footstep_concrete_000..004, pitched 0.6
##   a worker flees               creak2/3 + cloth2, pitch 1.5-1.9 (panic squeak)
##   a customer hunts             creak1/2 + cloth4 pitch 0.62 + impactPunch_medium
##   Service.mob_active           heartbeat pulse: a "lub" then a quieter "dub"
##   shop hover / refused         tick_001.ogg  /  back_001.ogg
##   music                        see [constant MUSIC_TRACKS] + [method play_music]

const RPG := "res://assets/kenney_rpg-audio/Audio/"
const IMPACT := "res://assets/kenney_impact-sounds/Audio/"
const UI := "res://assets/kenney_interface-sounds/Audio/"
const MUSIC := "res://assets/music/"

## The staff's footsteps: footstep00.ogg .. footstep09.ogg (RPG pack).
const STEP_FILES := 10
## The customers' footsteps: footstep_concrete_000.ogg .. _004.ogg (impact pack).
const HEAVY_STEP_FILES := 5
## The heartbeat's thump: a short concrete step, pitched right down.
const HEARTBEAT_FILE := IMPACT + "footstep_concrete_000.ogg"

## Music tracks by the short id the game UI uses (the user's own tracks in
## [code]assets/music/[/code]; the id is the word after the dash in the file
## name). [method play_music] also takes a full [code]res://[/code] path.
##   "build"  Airport Lounge - build.mp3    the build phase
##   "work"   District Four - work.mp3      the day / service phase
##   "lose"   Classic Horror 1 - lose.mp3   the horror / loss
const MUSIC_TRACKS := {
	"build": "res://assets/music/Airport%20Lounge - build.mp3",
	"work": "res://assets/music/District%20Four - work.mp3",
	"lose": "res://assets/music/Classic%20Horror%201 - lose.mp3",
}

## Volume a fading player starts from / fades to (effectively silent).
const SILENT_DB := -60.0

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

@export_group("Footsteps")
## Poll the walkers and step them across cells (turn off in tests / tools).
@export var footsteps_enabled := true
## Volume of a staff step, relative to [member master_volume_db] (dB).
@export var footstep_volume_db := -17.0
## Base pitch of a staff step (the file is already a footstep).
@export var footstep_pitch := 1.0
## Shortest gap between two staff steps, however many workers are walking.
@export var footstep_min_interval := 0.05
## Volume of a customer's step: heavier, so louder than a worker's.
@export var customer_footstep_volume_db := -7.0
## Pitch of a customer's step: low and slow, so it reads as a big creature.
@export var customer_footstep_pitch := 0.6
## Shortest gap between two customer steps.
@export var customer_footstep_min_interval := 0.08

@export_group("Horror")
## Volume of a fleeing worker's panic squeak (dB).
@export var panic_squeak_volume_db := -12.0
## How often one fleeing worker squeaks (seconds, jittered ±30 %).
@export var panic_squeak_interval := 0.65
## Shortest gap between two squeaks, however many workers are fleeing.
@export var panic_min_interval := 0.25
## Volume of a customer growl (dB).
@export var growl_volume_db := -7.0
## How often one customer growls (seconds, jittered ±25 %).
@export var growl_interval := 2.2
## Shortest gap between two growls, so a mob does not growl in chorus.
@export var growl_min_interval := 0.35
## Volume of the heartbeat pulse (dB).
@export var heartbeat_volume_db := -7.0
## Pitch of the heartbeat thump (0.45 = a low, dull thud).
@export var heartbeat_pitch := 0.45
## Seconds between beats while [member Service.mob_active] is true.
@export var heartbeat_interval := 0.62
## The second, softer half of the beat ("lub-dub"), in seconds after the lub.
@export var heartbeat_dub_delay := 0.17
## How much quieter the "dub" is than the "lub" (dB).
@export var heartbeat_dub_gain_db := -4.0

@export_group("Music")
## Music level, relative to [member master_volume_db] (dB).
@export var music_volume_db := -4.0
## Default fade for [method play_music] / [method stop_music] (seconds).
@export var music_fade_seconds := 1.2
## Loop the track (the imported MP3s ship unlooped; this is set at runtime).
@export var music_loop := true
## How far [method duck] pulls the music down by default (dB, negative).
@export var duck_amount_db := -9.0
## How fast the duck and its release fade (seconds).
@export var duck_fade_seconds := 0.15

var service: Service
var kitchen: Kitchen

var _players: Array[AudioStreamPlayer3D] = []
var _ui_players: Array[AudioStreamPlayer] = []
var _next_player := 0
var _next_ui := 0
var _streams: Dictionary = {}   # path -> AudioStream (or null when missing)
var _last_play: Dictionary = {} # throttle key -> msec

## Dedicated, non-positional players: the heartbeat is in the player's head and
## the music must survive every phase change (it sits under World/Fx, never
## rebuilt), so neither may be stolen by the pooled sound effects.
var _music: AudioStreamPlayer
var _heartbeat_lub: AudioStreamPlayer
var _heartbeat_dub_player: AudioStreamPlayer
var _music_tween: Tween
var _music_id := ""
var _music_current := ""
var _ducking := false

var _heartbeat := false
var _heartbeat_timer := 0.0
var _heartbeat_dub_left := 0.0

var _seen_cell: Dictionary = {}   # node instance id -> Vector2i (last cell seen)
var _panic_next: Dictionary = {}  # worker instance id -> msec of the next squeak
var _growl_next: Dictionary = {}  # customer instance id -> msec of the next growl

## How many sounds actually played (tests / tools read this).
var stats: Dictionary = {}
## How many calls the throttle swallowed.
var throttled: Dictionary = {}
## The last few sounds, for dev tools: "[t123] footstep @ (x, y, z)".
var recent: Array[String] = []


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
	_music = _new_channel("Music")
	_heartbeat_lub = _new_channel("HeartbeatLub")
	_heartbeat_dub_player = _new_channel("HeartbeatDub")


## Silence everything on the way out and let go of every stream: a playback or
## stream still referenced when the main loop quits is reported as a leaked
## instance / resource at exit (clearing the stream releases both).
func _exit_tree() -> void:
	_kill_music_tween()
	for channel in [_music, _heartbeat_lub, _heartbeat_dub_player]:
		if channel != null:
			channel.stop()
			channel.stream = null
	for player in _players:
		player.stop()
		player.stream = null
	for player in _ui_players:
		player.stop()
		player.stream = null


func _new_channel(channel_name: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = channel_name
	add_child(player)
	return player


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
# Presentation clock: the polled sounds (real time, never ticks)
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if service == null:
		return
	_poll_heartbeat(delta)
	if footsteps_enabled:
		_poll_steps()
	_poll_panic()
	_poll_growls()


## Footsteps: compare each walker's simulation cell against the one seen last
## frame. A cell change means it crossed a cell, which is exactly one step. The
## sound plays at the *visual* position, so it follows the glide, not the tick.
func _poll_steps() -> void:
	for worker in service.workers:
		if is_instance_valid(worker) and not worker.eaten:
			_step_if_moved(worker, false)
	for customer in service.customers:
		if is_instance_valid(customer):
			_step_if_moved(customer, true)
	_prune(_seen_cell)


func _step_if_moved(walker: Node3D, heavy: bool) -> void:
	var id := walker.get_instance_id()
	var cell := _cell_of(walker)
	if not _seen_cell.has(id):
		# first sighting: remember where it is, do not step on spawn
		_seen_cell[id] = cell
		return
	var last: Vector2i = _seen_cell[id]
	if last == cell:
		return
	_seen_cell[id] = cell
	if heavy:
		play_customer_footstep(walker.global_position)
	else:
		play_footstep(walker.global_position)


func _cell_of(walker: Node) -> Vector2i:
	if walker is Worker:
		return (walker as Worker).cell
	if walker is Customer:
		return (walker as Customer).cell
	return Vector2i.ZERO


## Fleeing workers squeak at a panicky, irregular rhythm.
func _poll_panic() -> void:
	var now := Time.get_ticks_msec()
	for worker in service.workers:
		if not is_instance_valid(worker) or worker.eaten:
			continue
		var id := worker.get_instance_id()
		if worker.state != Worker.State.FLEE:
			_panic_next.erase(id)
			continue
		if now < int(_panic_next.get(id, 0)):
			continue
		_panic_next[id] = now + int(panic_squeak_interval * randf_range(0.7, 1.3) * 1000.0)
		play_panic_squeak(worker.global_position + Vector3(0.0, 0.6, 0.0))
	_prune(_panic_next)


## Customers growl while they hunt: once as they climb in, then every couple of
## seconds (the throttle keeps a whole mob from growling in chorus).
func _poll_growls() -> void:
	var now := Time.get_ticks_msec()
	for customer in service.customers:
		if not is_instance_valid(customer):
			continue
		var id := customer.get_instance_id()
		if not _growl_next.has(id):
			_growl_next[id] = now + int(growl_interval * 1000.0)
			play_growl(customer.global_position)
			continue
		if now >= int(_growl_next[id]):
			_growl_next[id] = now + int(growl_interval * randf_range(0.75, 1.3) * 1000.0)
			play_growl(customer.global_position)
	_prune(_growl_next)


## The heartbeat follows [member Service.mob_active] on its own, so the horror
## starts and stops it even if nobody calls [method start_heartbeat].
func _poll_heartbeat(delta: float) -> void:
	if service.mob_active != _heartbeat:
		if service.mob_active:
			start_heartbeat()
		else:
			stop_heartbeat()
	if not _heartbeat:
		return
	if _heartbeat_dub_left > 0.0:
		_heartbeat_dub_left -= delta
		if _heartbeat_dub_left <= 0.0:
			_thump(_heartbeat_dub_player, heartbeat_dub_gain_db, 1.12)
	_heartbeat_timer -= delta
	if _heartbeat_timer <= 0.0:
		_heartbeat_timer = maxf(heartbeat_interval, 0.05)
		_heartbeat_dub_left = maxf(heartbeat_dub_delay, 0.0)
		_thump(_heartbeat_lub, 0.0, 1.0)


## One heartbeat thump on a dedicated channel: no pitch/volume jitter, so the
## pulse stays steady (the horror is the sound, not a random noise generator).
func _thump(player: AudioStreamPlayer, gain_db: float, pitch_scale: float) -> void:
	var stream := _stream(HEARTBEAT_FILE)
	if stream == null:
		return
	player.stream = stream
	player.pitch_scale = heartbeat_pitch * pitch_scale
	player.volume_db = heartbeat_volume_db + gain_db + master_volume_db
	player.play()
	_bump("heartbeat")


## Drops the tracking entry of every node that no longer exists.
func _prune(table: Dictionary) -> void:
	if table.size() <= 32:
		return
	for id: int in table.keys():
		if not is_instance_id_valid(id):
			table.erase(id)


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
	_log("%s @ %s" % [path.get_file(), position])
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
	_log("%s (ui)" % path.get_file())
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


## The files of every pooled player that is sounding right now (dev tools /
## tests). The dedicated music / heartbeat channels are reported by
## [method player_states] instead.
func sounding_paths() -> Array[String]:
	var out: Array[String] = []
	for player in _players:
		if player.playing and player.stream != null:
			out.append(player.stream.resource_path)
	for player in _ui_players:
		if player.playing and player.stream != null:
			out.append(player.stream.resource_path)
	return out


## Every player the bank owns, playing or not: "Sfx0=footstep03.ogg @-21.0dB".
## A dev-tool view of the pool; tests print it to show what is sounding.
func player_states() -> Array[String]:
	var out: Array[String] = []
	for player in _players:
		out.append(_state_line(player.name, player.playing, player.stream, player.volume_db))
	for player in _ui_players:
		out.append(_state_line(player.name, player.playing, player.stream, player.volume_db))
	out.append(_state_line("Music", _music.playing, _music.stream, _music.volume_db))
	out.append(_state_line("HeartbeatLub", _heartbeat_lub.playing, _heartbeat_lub.stream, _heartbeat_lub.volume_db))
	out.append(_state_line("HeartbeatDub", _heartbeat_dub_player.playing, _heartbeat_dub_player.stream, _heartbeat_dub_player.volume_db))
	return out


func _state_line(label: String, sounding: bool, stream: AudioStream, volume_db: float) -> String:
	if not sounding or stream == null:
		return "%s=-" % label
	return "%s=%s @%.1fdB" % [label, stream.resource_path.get_file(), volume_db]


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


func _log(text: String) -> void:
	recent.append("[t%d] %s" % [Time.get_ticks_msec(), text])
	if recent.size() > 200:
		recent.pop_front()


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


# ---------------------------------------------------------------------------
# Footsteps (one per cell crossed, polled above)
# ---------------------------------------------------------------------------

## One soft step for a member of staff. Called by the poll on every cell change;
## safe to call by hand for a scripted walk.
func play_footstep(position: Vector3) -> AudioStreamPlayer3D:
	var file := "footstep%02d.ogg" % (randi() % STEP_FILES)
	var player := play_throttled("footstep", footstep_min_interval, RPG + file,
		position, footstep_pitch, footstep_volume_db)
	if player != null:
		_bump("footstep")
	return player


## One heavy, low step for a customer: the concrete footstep pitched right down.
func play_customer_footstep(position: Vector3) -> AudioStreamPlayer3D:
	var file := "footstep_concrete_%03d.ogg" % (randi() % HEAVY_STEP_FILES)
	var player := play_throttled("customer_footstep", customer_footstep_min_interval,
		IMPACT + file, position, customer_footstep_pitch, customer_footstep_volume_db)
	if player != null:
		_bump("customer_footstep")
	return player


# ---------------------------------------------------------------------------
# The horror bed: panic squeaks, growls, the heartbeat
# ---------------------------------------------------------------------------

## A fleeing worker's panicky squeak (a creak / cloth pitched way up).
func play_panic_squeak(position: Vector3) -> AudioStreamPlayer3D:
	var squeaks := ["creak2.ogg", "creak3.ogg", "cloth2.ogg"]
	var file: String = squeaks[randi() % squeaks.size()]
	var player := play_throttled("squeak", panic_min_interval, RPG + file, position,
		randf_range(1.5, 1.9), panic_squeak_volume_db)
	if player != null:
		_bump("panic_squeak")
	return player


## A customer's growl: a rasp (creak / cloth) over a low punch body.
func play_growl(position: Vector3) -> AudioStreamPlayer3D:
	var now := Time.get_ticks_msec()
	if now - int(_last_play.get("growl", -1000000)) < int(growl_min_interval * 1000.0):
		_bump("throttled")
		return null
	_last_play["growl"] = now
	var rasps := ["creak1.ogg", "creak2.ogg", "cloth4.ogg"]
	var rasp: String = rasps[randi() % rasps.size()]
	play(RPG + rasp, position, 0.62, growl_volume_db)
	_bump("growl")
	return play(IMPACT + "impactPunch_medium_%03d.ogg" % (randi() % 5), position,
		0.5, growl_volume_db - 5.0)


## Starts the heartbeat pulse (the poll does this on its own when
## [member Service.mob_active] turns true; public for tools and cutscenes).
func start_heartbeat() -> void:
	if _heartbeat:
		return
	_heartbeat = true
	_heartbeat_timer = 0.0
	_heartbeat_dub_left = 0.0
	_bump("heartbeat_started")
	_log("heartbeat starts")


func stop_heartbeat() -> void:
	if not _heartbeat:
		return
	_heartbeat = false
	_heartbeat_timer = 0.0
	_heartbeat_dub_left = 0.0
	_bump("heartbeat_stopped")
	_log("heartbeat stops")


## Whether the pulse is running (it stays true between two thumps).
func is_heartbeat_active() -> bool:
	return _heartbeat


# ---------------------------------------------------------------------------
# UI tells (called by the shop and any other menu)
# ---------------------------------------------------------------------------

## A soft tick under a hovered shop card / button (call on mouse-enter).
## Throttled: dragging the mouse across a grid must not machine-gun it.
func play_hover() -> AudioStreamPlayer:
	var now := Time.get_ticks_msec()
	if now - int(_last_play.get("hover", -1000000)) < 40:
		_bump("throttled")
		return null
	_last_play["hover"] = now
	_bump("hover")
	return play_ui(UI + "tick_001.ogg", 1.05, -16.0)


## "No": the shop cannot afford the piece / the action is refused.
func play_refused() -> AudioStreamPlayer:
	_bump("refused")
	return play_ui(UI + "back_001.ogg", 0.95, -6.0)


## Alias of [method play_refused] (the name the day UI already uses).
func play_denied() -> AudioStreamPlayer:
	return play_refused()


# ---------------------------------------------------------------------------
# Music: a dedicated player that survives every phase change
# ---------------------------------------------------------------------------

## Resolves a track id (see [constant MUSIC_TRACKS]), a bare file name or a full
## path to a loadable path. Returns "" for an empty name.
func music_track_path(track: String) -> String:
	if MUSIC_TRACKS.has(track):
		var known: String = MUSIC_TRACKS[track]
		return known
	if track.begins_with("res://"):
		return track
	if track.is_empty():
		return ""
	# a bare file name: match it against the known tracks, with or without the
	# %20 encoding the imports carry
	var wanted := track.get_file().to_lower()
	for key in MUSIC_TRACKS.keys():
		var candidate: String = MUSIC_TRACKS[key]
		var file := candidate.get_file().to_lower()
		if file == wanted or file.uri_decode() == wanted:
			return candidate
	return MUSIC + track


## Plays a track, cross-fading from whatever is playing. [param track] is a short
## id ("build", "work", "lose") or a full [code]res://[/code] path.
## [param fade_seconds] below zero uses [member music_fade_seconds].
## Returns false when the file cannot be loaded (the caller keeps its state).
func play_music(track: String, fade_seconds := -1.0) -> bool:
	var path := music_track_path(track)
	if path.is_empty():
		push_warning("AudioBank: unknown music track '%s'" % track)
		return false
	var stream := _stream(path)
	if stream == null:
		return false
	_apply_music_loop(stream)
	var fade := music_fade_seconds if fade_seconds < 0.0 else fade_seconds
	if _music.playing and _music.stream == stream:
		# already on this track: just make sure it is back at full level
		_music_id = track
		_music_current = path
		_tween_music_to(_music_gain(), fade)
		return true
	if _music.playing:
		# cross-fade: down, swap, up
		_kill_music_tween()
		var half := maxf(fade * 0.5, 0.01)
		var out := create_tween()
		_music_tween = out
		out.tween_property(_music, "volume_db", SILENT_DB, half)
		out.tween_callback(_swap_music.bind(stream, path, track, half))
		return true
	_start_music(stream, path, track, fade)
	return true


## Fades the music out and stops the player. [param fade_seconds] below zero uses
## [member music_fade_seconds].
func stop_music(fade_seconds := -1.0) -> void:
	if not _music.playing:
		return
	var fade := music_fade_seconds if fade_seconds < 0.0 else fade_seconds
	_kill_music_tween()
	_ducking = false
	var out := create_tween()
	_music_tween = out
	out.tween_property(_music, "volume_db", SILENT_DB, maxf(fade, 0.01))
	out.tween_callback(_on_music_stopped)


## Drops the music for [param seconds] (an order card slamming in, a cutscene
## beat, a delivery jingle) and brings it back. [param amount_db] below zero
## overrides [member duck_amount_db].
func duck(seconds := 1.5, amount_db := 0.0) -> void:
	var amount := amount_db if amount_db < 0.0 else duck_amount_db
	var target := _music_gain()
	_kill_music_tween()
	_ducking = true
	var tween := create_tween()
	_music_tween = tween
	tween.tween_property(_music, "volume_db", target + amount, maxf(duck_fade_seconds, 0.01))
	tween.tween_interval(maxf(seconds, 0.0))
	tween.tween_property(_music, "volume_db", target, maxf(duck_fade_seconds, 0.2))
	tween.finished.connect(_on_duck_finished)
	_bump("duck")


func is_music_playing() -> bool:
	return _music.playing


## Whether a [method duck] is still holding the music down (true between the
## pull-down and the release, so the UI can avoid stacking ducks).
func is_ducked() -> bool:
	return _ducking


## The track that is loaded right now ("" once it has stopped).
func music_path() -> String:
	return _music_current


## The id [method play_music] was called with ("" once it has stopped).
func music_id() -> String:
	return _music_id


## The live music level in dB: the fade / duck value right now, not the target.
func music_gain_db() -> float:
	return _music.volume_db


## Where a full-level track sits: [member music_volume_db] + [member master_volume_db].
func music_target_db() -> float:
	return music_volume_db + master_volume_db


func _music_gain() -> float:
	return music_target_db()


func _start_music(stream: AudioStream, path: String, id: String, fade: float) -> void:
	_music.stream = stream
	_music.volume_db = SILENT_DB
	_music.play()
	_music_id = id
	_music_current = path
	_bump("music_started")
	_log("music: %s" % path.get_file())
	_tween_music_to(_music_gain(), fade)


## The tail of a cross-fade: the old track is down, bring the new one up.
func _swap_music(stream: AudioStream, path: String, id: String, fade: float) -> void:
	_start_music(stream, path, id, fade)


func _on_music_stopped() -> void:
	_music.stop()
	# release the stream too: a stopped player must not keep the playback alive
	_music.stream = null
	_music_current = ""
	_music_id = ""
	_bump("music_stopped")
	_log("music stops")


func _on_duck_finished() -> void:
	_ducking = false


func _tween_music_to(gain_db: float, seconds: float) -> void:
	_kill_music_tween()
	var tween := create_tween()
	_music_tween = tween
	tween.tween_property(_music, "volume_db", gain_db, maxf(seconds, 0.01))


func _kill_music_tween() -> void:
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
	_music_tween = null


## The imported tracks ship unlooped; looping is a runtime property of the
## stream, set here so the assets themselves are never touched.
func _apply_music_loop(stream: AudioStream) -> void:
	if stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = music_loop
	elif stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = music_loop


## "burger__no_cheese" / "serve__burger__none" -> "burger" / "serve".
func _base_recipe(recipe_id: StringName) -> String:
	var text := String(recipe_id)
	var cut := text.find("__")
	return text if cut < 0 else text.substr(0, cut)
