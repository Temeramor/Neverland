extends Node3D
class_name TerrainGenerator

## Compatibility adapter: keep Neverland's existing world controller and vegetation API.
## VoxEn prepares only the spawn chunk and collider; all other chunks stream in during play.

signal generation_started(seed_value: int)
signal generation_progress(seed_value: int, progress: float, status: String)
signal generation_finished(seed_value: int)

@export_group("World")
@export var world_size: float = 10000.0
@export_range(1024, 2048, 1024) var resolution: int = 2048
@export var world_seed: int = 1337

var _voxel_world: VoxelWorld
var _grass_field: Node3D
var _weather_mode: int = 1
var _generation_active: bool = false
var _progress_timer: float = 0.0


func _ready() -> void:
    _voxel_world = get_parent().get_node_or_null("VoxelWorld") as VoxelWorld
    if _voxel_world != null:
        _voxel_world.world_size_m = world_size


func generate(new_seed: int = 1337) -> void:
    if _voxel_world == null:
        _voxel_world = get_parent().get_node_or_null("VoxelWorld") as VoxelWorld
    if _voxel_world == null:
        push_error("Neverland: VoxEn VoxelWorld node is missing from world.tscn.")
        return
    world_seed = new_seed
    _generation_active = true
    _progress_timer = 0.0
    generation_started.emit(world_seed)
    generation_progress.emit(world_seed, 0.08, "Запускаем потоковую генерацию VoxEn...")
    _voxel_world.world_size_m = world_size
    _voxel_world.regenerate_with_seed(world_seed)


func _process(delta: float) -> void:
    if not _generation_active or _voxel_world == null:
        return
    _progress_timer += delta
    if _voxel_world.is_startup_loading():
        if _progress_timer >= 0.2:
            _progress_timer = 0.0
            generation_progress.emit(world_seed, _voxel_world.get_startup_progress(),
                "Готовим стартовый чанк и коллизию... (%d чанков)" % _voxel_world.get_loaded_chunk_count())
        return
    _generation_active = false
    _create_grass_field()
    generation_progress.emit(world_seed, 1.0,
        "Стартовая область готова; остальной мир загружается по ходу исследования.")
    generation_finished.emit(world_seed)


func _create_grass_field() -> void:
    if is_instance_valid(_grass_field):
        _grass_field.queue_free()
        _grass_field = null
    var grass_scene := load("res://assets/terrain/grass/GrassField.tscn") as PackedScene
    if grass_scene == null:
        return
    _grass_field = grass_scene.instantiate() as Node3D
    _grass_field.name = "ProceduralGrassField"
    _grass_field.call("configure", self, world_seed)
    add_child(_grass_field)
    _grass_field.call("set_weather", _weather_mode)


func set_weather(mode: int) -> void:
    _weather_mode = clampi(mode, 0, 2)
    if is_instance_valid(_grass_field):
        _grass_field.call("set_weather", _weather_mode)


func height_at_world(world_x: float, world_z: float) -> float:
    if _voxel_world == null:
        return 25.0
    return _voxel_world.get_surface_height(world_x, world_z)


func surface_sample_at_world(world_x: float, world_z: float) -> Vector3:
    if _voxel_world == null:
        return Vector3(25.0, 0.0, 0.0)
    return _voxel_world.surface_sample_at_world(world_x, world_z)


func get_render_distance_m() -> float:
    if _voxel_world == null:
        return 256.0
    return _voxel_world.render_distance_m


func get_debug_text() -> String:
    if _voxel_world == null:
        return "VoxEn 0.3.5 — ожидание VoxelWorld"
    return _voxel_world.get_debug_text()
