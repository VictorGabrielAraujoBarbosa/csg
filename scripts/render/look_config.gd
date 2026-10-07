@tool
class_name LookConfig
extends WorldEnvironment
## Inspector panel for the whole look: sky, ambient fill, SSAO, glow and color
## grading. This node owns the [Environment] it builds from these properties,
## so the values here are the single source of truth, tweakable live in the
## editor and at runtime.
##
## (Read "AO" as the PlateUp-style darkening in the corners: no real shadows,
## just ambient occlusion around walls and furniture.)

@export_group("Sky")
@export var sky_top_color := Color(0.58, 0.62, 0.68):
	set(value):
		sky_top_color = value
		_apply()
@export var sky_horizon_color := Color(0.8, 0.82, 0.85):
	set(value):
		sky_horizon_color = value
		_apply()
@export var ground_bottom_color := Color(0.3, 0.31, 0.34):
	set(value):
		ground_bottom_color = value
		_apply()
@export var ground_horizon_color := Color(0.8, 0.82, 0.85):
	set(value):
		ground_horizon_color = value
		_apply()

@export_group("Ambient")
@export_range(0.0, 2.0, 0.01) var ambient_energy := 0.85:
	set(value):
		ambient_energy = value
		_apply()
## 1 = ambient comes from the sky colours, 0 = from [member ambient_color].
@export_range(0.0, 1.0, 0.01) var ambient_sky_contribution := 0.45:
	set(value):
		ambient_sky_contribution = value
		_apply()
@export var ambient_color := Color(0.86, 0.87, 0.9):
	set(value):
		ambient_color = value
		_apply()

@export_group("SSAO (contact darkening)")
@export var ssao_enabled := true:
	set(value):
		ssao_enabled = value
		_apply()
@export_range(0.0, 2.0, 0.01) var ssao_radius := 1.4:
	set(value):
		ssao_radius = value
		_apply()
@export_range(0.0, 4.0, 0.01) var ssao_intensity := 3.5:
	set(value):
		ssao_intensity = value
		_apply()
@export_range(0.0, 4.0, 0.01) var ssao_power := 1.5:
	set(value):
		ssao_power = value
		_apply()
@export_range(0.0, 1.0, 0.01) var ssao_detail := 0.5:
	set(value):
		ssao_detail = value
		_apply()

@export_group("Glow")
@export var glow_enabled := true:
	set(value):
		glow_enabled = value
		_apply()
@export_range(0.0, 4.0, 0.01) var glow_intensity := 0.25:
	set(value):
		glow_intensity = value
		_apply()
@export_range(0.0, 4.0, 0.01) var glow_bloom := 0.0:
	set(value):
		glow_bloom = value
		_apply()
@export_range(0.0, 4.0, 0.01) var glow_hdr_threshold := 1.1:
	set(value):
		glow_hdr_threshold = value
		_apply()

@export_group("Grading")
@export var grading_enabled := true:
	set(value):
		grading_enabled = value
		_apply()
@export_range(0.0, 2.0, 0.01) var saturation := 1.1:
	set(value):
		saturation = value
		_apply()
@export_range(0.0, 2.0, 0.01) var contrast := 1.1:
	set(value):
		contrast = value
		_apply()
@export_range(0.0, 2.0, 0.01) var brightness := 1.0:
	set(value):
		brightness = value
		_apply()
@export_enum("Linear", "Reinhard", "Filmic", "ACES") var tonemap := 3:
	set(value):
		tonemap = value
		_apply()
@export_range(0.0, 4.0, 0.01) var tonemap_exposure := 0.95:
	set(value):
		tonemap_exposure = value
		_apply()
@export_range(0.0, 8.0, 0.01) var tonemap_white := 1.0:
	set(value):
		tonemap_white = value
		_apply()


func _ready() -> void:
	_apply()


func _apply() -> void:
	if not is_inside_tree():
		return
	var env := environment
	if env == null:
		env = Environment.new()
		environment = env
	var sky := _make_sky()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = ambient_energy
	env.ambient_light_sky_contribution = ambient_sky_contribution
	env.ambient_light_color = ambient_color
	env.ssao_enabled = ssao_enabled
	env.ssao_radius = ssao_radius
	env.ssao_intensity = ssao_intensity
	env.ssao_power = ssao_power
	env.ssao_detail = ssao_detail
	env.glow_enabled = glow_enabled
	env.glow_intensity = glow_intensity
	env.glow_bloom = glow_bloom
	env.glow_hdr_threshold = glow_hdr_threshold
	env.adjustment_enabled = grading_enabled
	env.adjustment_saturation = saturation
	env.adjustment_contrast = contrast
	env.adjustment_brightness = brightness
	env.tonemap_mode = tonemap
	env.tonemap_exposure = tonemap_exposure
	env.tonemap_white = tonemap_white


func _make_sky() -> Sky:
	var sky: Sky = environment.sky
	var mat: ProceduralSkyMaterial = null
	if sky != null and sky.sky_material is ProceduralSkyMaterial:
		mat = sky.sky_material
	if sky == null:
		sky = Sky.new()
	if mat == null:
		mat = ProceduralSkyMaterial.new()
		sky.sky_material = mat
	mat.sky_top_color = sky_top_color
	mat.sky_horizon_color = sky_horizon_color
	mat.ground_bottom_color = ground_bottom_color
	mat.ground_horizon_color = ground_horizon_color
	return sky
