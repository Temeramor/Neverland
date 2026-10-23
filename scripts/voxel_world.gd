extends Node3D
class_name VoxelWorld

const VOXEL_SIZE: float = 0.1
const GeneratorScript = preload("res://scripts/voxel_generator.gd")
const ChunkScript = preload("res://scripts/voxel_chunk.gd")
const BuilderScript = preload("res://scripts/voxel_chunk_builder.gd")

@export_category("Voxel world")
@export_range(256.0, 20000.0, 256.0) var world_size_m: float = 10000.0
@export_range(8.0, 32.0, 8.0) var chunk_size_m: float = 16.0
@export var seed_value: int = 1337
@export var auto_start_on_ready: bool = true

@export_category("Streaming and LOD")
@export_range(64.0, 320.0, 16.0) var render_distance_m: float = 256.0
@export_range(32.0, 128.0, 16.0) var unload_margin_m: float = 80.0
@export_range(16.0, 48.0, 8.0) var lod0_distance_m: float = 32.0
@export_range(32.0, 80.0, 8.0) var lod1_distance_m: float = 56.0
@export_range(64.0, 128.0, 8.0) var lod2_distance_m: float = 96.0
@export_range(96.0, 192.0, 16.0) var lod3_distance_m: float = 160.0
@export_range(2.0, 12.0, 2.0) var lod_hysteresis_m: float = 6.0
@export_range(1, 12, 1) var max_concurrent_mesh_jobs: int = 6
@export_range(1, 4, 1) var max_mesh_applies_per_frame: int = 3
@export_range(1.0, 8.0, 0.5) var max_mesh_apply_time_ms: float = 4.0
@export_range(0.01, 0.2, 0.01) var streaming_refresh_interval_s: float = 0.02
@export_range(0.25, 4.0, 0.25) var streaming_refresh_distance_m: float = 0.5
@export_range(0.5, 2.5, 0.1) var streaming_prediction_seconds: float = 1.4

@export_category("Collision")
@export_range(16.0, 128.0, 8.0) var collision_distance_m: float = 80.0

var _generator: VoxelTerrainGenerator
var _voxel_material: ShaderMaterial
var _player: CharacterBody3D
var _chunks: Dictionary = {}
var _queued: Dictionary = {}
var _wanted: Dictionary = {}
var _running_tasks: Dictionary = {}
var _running_by_coord: Dictionary = {}
var _completed_jobs: Dictionary = {}
var _refresh_timer: float = 0.0
var _debug_lod_colors: bool = false
var _last_player_position := Vector2(INF, INF)
var _last_refresh_chunk := Vector2i(-2147483648, -2147483648)
var _world_size_voxels: int
var _chunk_size_voxels: int
var _world_min_x: float
var _world_min_z: float
var _chunks_per_axis: int
var _lod_state_cache: Dictionary = {}
var _retiring_chunks: Array[VoxelTerrainChunk] = []
var _generation_epoch: int = 0
var _startup_load_pending: bool = true
var _build_usec_by_lod: Array = [[], [], [], [], []]
var _build_p95_cached_usec: Array[float] = [80000.0, 30000.0, 12000.0, 6000.0, 3000.0]
var _refresh_usec_samples: Array[int] = []
var _refresh_p95_cached_usec: float = 0.0
var _queue_wait_usec_samples: Array[int] = []
var _apply_wait_usec_samples: Array[int] = []
var _queue_wait_p95_cached_usec: float = 0.0
var _apply_wait_p95_cached_usec: float = 0.0
var _build_estimate_refresh_timer: float = 0.0
var _max_queue_wait_usec: int = 0
var _stale_result_count: int = 0
var _world_started: bool = false

func _ready() -> void:
    _world_size_voxels = int(round(world_size_m / VOXEL_SIZE))
    _chunk_size_voxels = int(round(chunk_size_m / VOXEL_SIZE))
    _world_min_x = -world_size_m * 0.5
    _world_min_z = -world_size_m * 0.5
    _chunks_per_axis = int(ceil(float(_world_size_voxels) / float(_chunk_size_voxels)))
    _generator = GeneratorScript.new(seed_value, world_size_m)

    var surface_shader := load("res://shaders/voxel_surface.gdshader") as Shader
    _voxel_material = ShaderMaterial.new()
    _voxel_material.shader = surface_shader
    _apply_seed_to_material()

    _player = get_node_or_null(NodePath("../Player")) as CharacterBody3D
    if _player != null:
        # Do not let gravity move the player before the spawn chunk's collider exists.
        _player.set_physics_process(false)
        _player.velocity = Vector3.ZERO
        _player.global_position = Vector3(0.0, get_surface_height(0.0, 0.0) + 8.0, 0.0)
        _startup_load_pending = true

    if auto_start_on_ready:
        _world_started = true
        _refresh_streaming()

func _process(delta: float) -> void:
    _build_estimate_refresh_timer += delta
    if _build_estimate_refresh_timer >= 0.5:
        _build_estimate_refresh_timer = 0.0
        _refresh_build_estimate_cache()

    _refresh_timer += delta
    if _refresh_timer >= streaming_refresh_interval_s and _world_started:
        _refresh_timer = 0.0
        if _player != null:
            var player_position := Vector2(_player.global_position.x, _player.global_position.z)
            var current_chunk := Vector2i(
                clampi(floori((player_position.x - _world_min_x) / chunk_size_m), 0, _chunks_per_axis - 1),
                clampi(floori((player_position.y - _world_min_z) / chunk_size_m), 0, _chunks_per_axis - 1)
            )
            if player_position.distance_to(_last_player_position) >= streaming_refresh_distance_m or current_chunk != _last_refresh_chunk:
                _last_player_position = player_position
                _last_refresh_chunk = current_chunk
                _refresh_streaming()

    _poll_worker_tasks()
    _apply_completed_jobs()
    _process_chunk_jobs()
    _retire_stale_resources()
    _try_finish_startup_loading()

func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventKey and event.pressed and not event.echo):
        return
    if event.keycode == KEY_F3:
        _debug_lod_colors = not _debug_lod_colors
        if _voxel_material != null:
            _voxel_material.set_shader_parameter("debug_lod_colors", _debug_lod_colors)
        _refresh_streaming()
    elif event.keycode == KEY_R:
        regenerate_with_random_seed()

func regenerate_with_random_seed() -> void:
    var rng := RandomNumberGenerator.new()
    rng.randomize()
    var next_seed: int = rng.randi_range(1, 2147483646)
    if next_seed == seed_value:
        next_seed = 1 if seed_value != 1 else 2
    regenerate_with_seed(next_seed)

func regenerate_with_seed(new_seed: int) -> void:
    # Existing worker tasks cannot be cancelled safely; their epoch makes their results stale.
    _world_started = true
    _generation_epoch += 1
    seed_value = new_seed
    _queued.clear()
    _wanted.clear()
    _completed_jobs.clear()
    _lod_state_cache.clear()

    # Hide the old world immediately; release mesh buffers gradually over later frames.
    # In-flight tasks finish, but their old epoch will reject their results.
    for chunk_value in _chunks.values():
        var old_chunk: VoxelTerrainChunk = chunk_value as VoxelTerrainChunk
        old_chunk.set_render_active(false)
        old_chunk._retire_current_generation()
        remove_child(old_chunk)
        _retiring_chunks.append(old_chunk)
    _chunks.clear()

    _generator = GeneratorScript.new(seed_value, world_size_m)
    _apply_seed_to_material()
    if _player != null:
        _player.set_physics_process(false)
        _player.velocity = Vector3.ZERO
        _player.global_position = Vector3(0.0, get_surface_height(0.0, 0.0) + 8.0, 0.0)
        _startup_load_pending = true
    _last_player_position = Vector2(INF, INF)
    _last_refresh_chunk = Vector2i(-2147483648, -2147483648)
    _refresh_streaming()

func _apply_seed_to_material() -> void:
    if _voxel_material == null:
        return
    var safe_seed: int = abs(seed_value % 2147483647)
    _voxel_material.set_shader_parameter("seed_low", float(safe_seed % 65536))
    _voxel_material.set_shader_parameter("seed_high", float(int(floor(float(safe_seed) / 65536.0))))
    _voxel_material.set_shader_parameter("debug_lod_colors", _debug_lod_colors)

func get_surface_height(x: float, z: float) -> float:
    if _generator == null:
        _generator = GeneratorScript.new(seed_value, world_size_m)
    return float(_generator.get_surface_height_voxels(x, z)) * VOXEL_SIZE

func get_voxel_material(global_voxel: Vector3i) -> int:
    if _generator == null:
        _generator = GeneratorScript.new(seed_value, world_size_m)
    return _generator.get_voxel_material(global_voxel, _world_min_x, _world_min_z, _world_size_voxels)

func get_debug_text() -> String:
    var lod_counts: Array[int] = [0, 0, 0, 0, 0]
    var collider_count: int = 0
    var near_pending: int = 0
    for coord_value in _chunks.keys():
        var chunk: VoxelTerrainChunk = _chunks[coord_value] as VoxelTerrainChunk
        if chunk.lod >= 0 and chunk.lod < lod_counts.size():
            lod_counts[chunk.lod] += 1
        if chunk.collision_active:
            collider_count += 1
    for coord_value in _wanted.keys():
        var coord: Vector2i = coord_value
        var request: Dictionary = _wanted[coord]
        if float(request.get("nearest_distance", INF)) > 40.0:
            continue
        var near_chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
        if near_chunk == null or not near_chunk.mesh_ready or near_chunk.lod != int(request["lod"]):
            near_pending += 1
    var l0: Array = _build_usec_by_lod[0]
    var l1: Array = _build_usec_by_lod[1]
    var planar_speed: float = 0.0
    if _player != null:
        planar_speed = Vector2(_player.velocity.x, _player.velocity.z).length()
    var prediction_seconds: float = _effective_prediction_seconds()
    var estimated_work_seconds: float = _estimated_lod_pipeline_usec(0) / 1000000.0
    var lead_margin_m: float = planar_speed * (prediction_seconds - estimated_work_seconds)
    return "VoxEn 0.3.5 | seed %d | chunks %d | LOD 0:%d 1:%d 2:%d 3:%d 4:%d | colliders %d | jobs %d+%d | near pending %d | stale %d\nBuild avg/p95 ms: L0 %.1f/%.1f L1 %.1f/%.1f | refresh p95 %.2f ms | queue p95/max %.0f/%.1f ms | apply p95 %.0f ms | L0 margin %.1f m (pred %.1fs)" % [
        seed_value, _chunks.size(), lod_counts[0], lod_counts[1], lod_counts[2], lod_counts[3], lod_counts[4],
        collider_count, _running_tasks.size(), _queued.size(), near_pending, _stale_result_count,
        _avg_ms(l0), _build_p95_cached_usec[0] / 1000.0, _avg_ms(l1), _build_p95_cached_usec[1] / 1000.0,
        _refresh_p95_cached_usec / 1000.0, _queue_wait_p95_cached_usec / 1000.0,
        float(_max_queue_wait_usec) / 1000.0, _apply_wait_p95_cached_usec / 1000.0,
        lead_margin_m, prediction_seconds
    ]

func is_startup_loading() -> bool:
    return _startup_load_pending

func get_loaded_chunk_count() -> int:
    return _chunks.size()

func get_startup_progress() -> float:
    if not _startup_load_pending:
        return 1.0
    var built_count: int = 0
    for chunk_value in _chunks.values():
        var chunk := chunk_value as VoxelTerrainChunk
        if chunk != null and chunk.mesh_ready:
            built_count += 1
    return clampf(0.12 + float(built_count) * 0.12, 0.12, 0.84)

func surface_sample_at_world(world_x: float, world_z: float) -> Vector3:
    if _generator == null:
        _generator = GeneratorScript.new(seed_value, world_size_m)
    return _generator.get_surface_sample(world_x, world_z)

func _try_finish_startup_loading() -> void:
    if not _startup_load_pending or _player == null:
        return
    var local_x: float = _player.global_position.x - _world_min_x
    var local_z: float = _player.global_position.z - _world_min_z
    var spawn_coord := Vector2i(
        clampi(floori(local_x / chunk_size_m), 0, _chunks_per_axis - 1),
        clampi(floori(local_z / chunk_size_m), 0, _chunks_per_axis - 1)
    )
    var spawn_chunk: VoxelTerrainChunk = _chunks.get(spawn_coord) as VoxelTerrainChunk
    if spawn_chunk != null and spawn_chunk.mesh_ready and spawn_chunk.collision_active:
        _place_player_on_surface()

func _chunk_has_collision_resource(coord: Vector2i) -> bool:
    var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
    return chunk != null and chunk.collision_enabled

func can_move_to_position(world_position: Vector3, safety_margin_m: float = 0.6) -> bool:
    # Check all four horizontal footprint corners so the capsule cannot enter a
    # chunk before its heightmap shape is active.
    for offset_z in [-safety_margin_m, safety_margin_m]:
        for offset_x in [-safety_margin_m, safety_margin_m]:
            var point := Vector2(world_position.x + offset_x, world_position.z + offset_z)
            var local_x: float = point.x - _world_min_x
            var local_z: float = point.y - _world_min_z
            if local_x < 0.0 or local_z < 0.0 or local_x >= world_size_m or local_z >= world_size_m:
                return false
            var coord := Vector2i(floori(local_x / chunk_size_m), floori(local_z / chunk_size_m))
            var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
            if chunk == null or not chunk.collision_active:
                return false
    return true

func _refresh_streaming() -> void:
    if _player == null or _generator == null:
        return

    var refresh_started_usec: int = Time.get_ticks_usec()
    var player_xz := Vector2(_player.global_position.x, _player.global_position.z)
    var heading: Vector2 = _get_streaming_heading()
    var planar_velocity := Vector2(_player.velocity.x, _player.velocity.z)
    var predicted_player_xz: Vector2 = player_xz
    if planar_velocity.length() >= 2.0:
        predicted_player_xz += planar_velocity * _effective_prediction_seconds()
    var wanted: Dictionary = {}
    var load_radius: float = render_distance_m + chunk_size_m
    var keep_radius: float = render_distance_m + unload_margin_m
    var center_chunk_x: int = clampi(floori((player_xz.x - _world_min_x) / chunk_size_m), 0, _chunks_per_axis - 1)
    var center_chunk_z: int = clampi(floori((player_xz.y - _world_min_z) / chunk_size_m), 0, _chunks_per_axis - 1)
    var chunk_radius: int = int(ceil(load_radius / chunk_size_m)) + 1

    # Visit only the nearby chunk-coordinate window, not every chunk in the 1 km world.
    for cz in range(maxi(0, center_chunk_z - chunk_radius), mini(_chunks_per_axis, center_chunk_z + chunk_radius + 1)):
        for cx in range(maxi(0, center_chunk_x - chunk_radius), mini(_chunks_per_axis, center_chunk_x + chunk_radius + 1)):
            var coord := Vector2i(cx, cz)
            var bounds := _chunk_bounds(coord)
            var center: Vector2 = bounds["center"]
            var nearest_distance: float = _distance_to_chunk_bounds(player_xz, bounds)
            var center_distance: float = center.distance_to(player_xz)
            if nearest_distance <= load_radius:
                var size_x: int = int(bounds["size_x"])
                var size_z: int = int(bounds["size_z"])
                var desired_lod: int = _lod_for_coord(coord, player_xz)
                if planar_velocity.length() >= 2.0:
                    var predicted_lod: int = _lod_for_distance(center.distance_to(predicted_player_xz))
                    if predicted_lod < desired_lod:
                        desired_lod = predicted_lod
                        _lod_state_cache[coord] = desired_lod
                wanted[coord] = {
                    "lod": desired_lod,
                    "distance": center_distance,
                    "nearest_distance": nearest_distance,
                    "priority": center_distance - maxf(0.0, (center - player_xz).dot(heading)) * 0.30,
                    "collision": nearest_distance <= collision_distance_m,
                    "start_x": int(bounds["start_x"]),
                    "start_z": int(bounds["start_z"]),
                    "size_x": size_x,
                    "size_z": size_z
                }

    _wanted = wanted

    for queued_coord in _queued.keys():
        if not wanted.has(queued_coord):
            _queued.erase(queued_coord)

    for existing_coord in _chunks.keys():
        var existing_chunk: VoxelTerrainChunk = _chunks[existing_coord] as VoxelTerrainChunk
        if wanted.has(existing_coord):
            continue
        var existing_bounds := _chunk_bounds(existing_coord)
        if _distance_to_chunk_bounds(player_xz, existing_bounds) > keep_radius:
            var was_render_active_before_retire: bool = existing_chunk._render_active
            existing_chunk.set_render_active(false)
            existing_chunk._retire_current_generation()
            remove_child(existing_chunk)
            _retiring_chunks.append(existing_chunk)
            _chunks.erase(existing_coord)
            _completed_jobs.erase(existing_coord)
            _queued.erase(existing_coord)
            if was_render_active_before_retire:
                _update_neighbor_chunk_skirts(existing_coord)
        else:
            # Keep recent chunks cached but invisible and non-collidable for quick reversals.
            var was_render_active_before_hide: bool = existing_chunk._render_active
            existing_chunk.set_render_active(false)
            if was_render_active_before_hide:
                _update_neighbor_chunk_skirts(existing_coord)

    for coord in wanted.keys():
        var request: Dictionary = wanted[coord]
        var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
        var needs_build: bool = chunk == null
        if chunk != null:
            var was_render_active_before_reactivate: bool = chunk._render_active
            chunk.set_render_active(true, bool(request["collision"]))
            _update_chunk_skirt_visibility(coord, chunk)
            if not was_render_active_before_reactivate:
                _update_neighbor_chunk_skirts(coord)
            needs_build = (
                chunk.lod != int(request["lod"])
                or chunk.debug_lod_colors != _debug_lod_colors
                or (bool(request["collision"]) and not chunk.collision_enabled)
            )

        if _running_job_matches(coord, request) or _completed_job_matches(coord, request):
            _queued.erase(coord)
        elif needs_build:
            var previous_queue: Dictionary = _queued.get(coord, {})
            if not previous_queue.is_empty() and int(previous_queue.get("lod", -1)) == int(request["lod"]) and bool(previous_queue.get("collision", false)) == bool(request["collision"]):
                request["queued_usec"] = int(previous_queue.get("queued_usec", Time.get_ticks_usec()))
            else:
                request["queued_usec"] = Time.get_ticks_usec()
            _queued[coord] = request
        else:
            _queued.erase(coord)

    # Measure the complete refresh, including resident-chunk state transitions.
    _record_timing(_refresh_usec_samples, Time.get_ticks_usec() - refresh_started_usec, 96)

func _update_chunk_skirt_visibility(coord: Vector2i, chunk: VoxelTerrainChunk) -> void:
    if chunk == null or not chunk.mesh_ready:
        return
    var left_coord: Vector2i = coord + Vector2i(-1, 0)
    var right_coord: Vector2i = coord + Vector2i(1, 0)
    var north_coord: Vector2i = coord + Vector2i(0, -1)
    var south_coord: Vector2i = coord + Vector2i(0, 1)
    var left_lod: int = _target_lod_for_neighbor(left_coord)
    var right_lod: int = _target_lod_for_neighbor(right_coord)
    var north_lod: int = _target_lod_for_neighbor(north_coord)
    var south_lod: int = _target_lod_for_neighbor(south_coord)
    chunk.set_skirt_visibility(Vector4(
        1.0 if _should_show_chunk_skirt(left_coord, chunk, left_lod) else 0.0,
        1.0 if _should_show_chunk_skirt(right_coord, chunk, right_lod) else 0.0,
        1.0 if _should_show_chunk_skirt(north_coord, chunk, north_lod) else 0.0,
        1.0 if _should_show_chunk_skirt(south_coord, chunk, south_lod) else 0.0
    ))

func _should_show_chunk_skirt(neighbor_coord: Vector2i, chunk: VoxelTerrainChunk, target_lod: int) -> bool:
    if target_lod < 0 or target_lod != chunk.lod:
        return target_lod >= 0
    var neighbor: VoxelTerrainChunk = _chunks.get(neighbor_coord) as VoxelTerrainChunk
    if neighbor == null or not neighbor.mesh_ready or not neighbor._render_active:
        return true
    return neighbor.lod != chunk.lod

func _update_neighbor_chunk_skirts(coord: Vector2i) -> void:
    for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
        var neighbor_coord: Vector2i = coord + offset
        var neighbor: VoxelTerrainChunk = _chunks.get(neighbor_coord) as VoxelTerrainChunk
        if neighbor != null and neighbor.mesh_ready:
            _update_chunk_skirt_visibility(neighbor_coord, neighbor)

func _chunk_bounds(coord: Vector2i) -> Dictionary:
    var start_voxel_x: int = coord.x * _chunk_size_voxels
    var start_voxel_z: int = coord.y * _chunk_size_voxels
    var size_voxels_x: int = mini(_chunk_size_voxels, _world_size_voxels - start_voxel_x)
    var size_voxels_z: int = mini(_chunk_size_voxels, _world_size_voxels - start_voxel_z)
    var origin_x: float = _world_min_x + float(start_voxel_x) * VOXEL_SIZE
    var origin_z: float = _world_min_z + float(start_voxel_z) * VOXEL_SIZE
    var width: float = float(size_voxels_x) * VOXEL_SIZE
    var depth: float = float(size_voxels_z) * VOXEL_SIZE
    return {
        "start_x": start_voxel_x,
        "start_z": start_voxel_z,
        "size_x": size_voxels_x,
        "size_z": size_voxels_z,
        "origin": Vector2(origin_x, origin_z),
        "center": Vector2(origin_x + width * 0.5, origin_z + depth * 0.5),
        "width": width,
        "depth": depth
    }

func _distance_to_chunk_bounds(point: Vector2, bounds: Dictionary) -> float:
    var center: Vector2 = bounds["center"]
    var width: float = float(bounds["width"])
    var depth: float = float(bounds["depth"])
    var nearest_x: float = maxf(0.0, absf(point.x - center.x) - width * 0.5)
    var nearest_z: float = maxf(0.0, absf(point.y - center.y) - depth * 0.5)
    return Vector2(nearest_x, nearest_z).length()

func _process_chunk_jobs() -> void:
    var worker_limit: int = maxi(1, mini(max_concurrent_mesh_jobs, maxi(1, OS.get_processor_count() - 1)))
    var available_jobs: int = worker_limit - _running_tasks.size()
    if available_jobs <= 0 or _queued.is_empty():
        return
    var started_jobs: int = 0
    var player_xz := _player_xz()
    var heading: Vector2 = _get_streaming_heading()
    var planar_velocity := Vector2(_player.velocity.x, _player.velocity.z) if _player != null else Vector2.ZERO
    while started_jobs < available_jobs and not _queued.is_empty():
        var best_coord := Vector2i(-1, -1)
        var best_priority: float = INF
        var best_center := Vector2.ZERO
        for queued_key in _queued.keys():
            var candidate: Vector2i = queued_key
            if _running_by_coord.has(candidate):
                continue
            var candidate_center: Vector2 = _chunk_center(candidate)
            var candidate_request: Dictionary = _queued[candidate]
            var priority: float = _deadline_priority(candidate_center, candidate_request, player_xz, heading, planar_velocity)
            if priority < best_priority:
                best_priority = priority
                best_coord = candidate
                best_center = candidate_center
        if best_coord.x < 0:
            break
        var coord: Vector2i = best_coord
        var request: Dictionary = _queued[coord]
        request["distance"] = best_center.distance_to(player_xz)
        request["priority"] = best_priority
        if not request.has("queued_usec"):
            request["queued_usec"] = Time.get_ticks_usec()
        _queued.erase(coord)
        var neighbors: Dictionary = _neighbor_lods_for(coord)
        var job_data: Dictionary = {
            "coord": coord, "request": request.duplicate(true), "neighbor_lods": neighbors.duplicate(true),
            "seed": seed_value, "world_min_x": _world_min_x, "world_min_z": _world_min_z,
            "world_size_voxels": _world_size_voxels, "debug_lod_colors": _debug_lod_colors,
            "terrain_world_size_m": world_size_m, "mountain_profile": _generator.get_mountain_profile(),
            "build_collision": bool(request["collision"]) and not _chunk_has_collision_resource(coord)
        }
        var builder: Object = _create_mesh_builder()
        var task_id: int = WorkerThreadPool.add_task(
            Callable(builder, "build_mesh_data").bind(job_data), false,
            "VoxEn chunk %d,%d LOD%d" % [coord.x, coord.y, int(request["lod"])]
        )
        var task_record := {
            "coord": coord, "request": request.duplicate(true), "neighbors": neighbors.duplicate(true),
            "builder": builder, "epoch": _generation_epoch, "debug": _debug_lod_colors,
            "seed": seed_value, "queued_usec": int(request["queued_usec"])
        }
        _running_tasks[task_id] = task_record
        _running_by_coord[coord] = task_id
        started_jobs += 1

func _create_mesh_builder() -> Object:
    # Use the native CPU-only mesher when its library is installed; otherwise keep the
    # proven GDScript path so source-only checkouts remain usable.
    if ClassDB.class_exists("VoxEnNativeBuilder"):
        var native_builder: Object = ClassDB.instantiate("VoxEnNativeBuilder")
        if native_builder != null:
            return native_builder
    return BuilderScript.new()

func _poll_worker_tasks() -> void:
    for task_key in _running_tasks.keys():
        var task_id: int = int(task_key)
        if not WorkerThreadPool.is_task_completed(task_id):
            continue
        WorkerThreadPool.wait_for_task_completion(task_id)
        var record: Dictionary = _running_tasks[task_id]
        _running_tasks.erase(task_id)
        var coord: Vector2i = record["coord"]
        if int(_running_by_coord.get(coord, -1)) == task_id:
            _running_by_coord.erase(coord)
        var builder = record["builder"]
        var data: Dictionary = builder.result
        if data.is_empty():
            if _wanted.has(coord):
                var retry_empty: Dictionary = _wanted[coord].duplicate(true)
                retry_empty["queued_usec"] = Time.get_ticks_usec()
                _queued[coord] = retry_empty
            continue
        var lod_index: int = clampi(int(data.get("lod", record["request"]["lod"])), 0, 4)
        _record_timing(_build_usec_by_lod[lod_index], int(data.get("build_usec", 0)), 128)
        var queue_wait_usec: int = maxi(0, int(data.get("worker_started_usec", Time.get_ticks_usec())) - int(record.get("queued_usec", Time.get_ticks_usec())))
        _max_queue_wait_usec = maxi(_max_queue_wait_usec, queue_wait_usec)
        _record_timing(_queue_wait_usec_samples, queue_wait_usec, 128)
        if _job_record_matches_current(record, coord):
            record["data"] = data
            record["completed_usec"] = Time.get_ticks_usec()
            _completed_jobs[coord] = record
        else:
            _stale_result_count += 1
            if _wanted.has(coord) and not _running_by_coord.has(coord):
                var retry: Dictionary = _wanted[coord].duplicate(true)
                retry["queued_usec"] = Time.get_ticks_usec()
                _queued[coord] = retry

func _apply_completed_jobs() -> void:
    if _completed_jobs.is_empty():
        return

    var coords: Array = _completed_jobs.keys()
    coords.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        var distance_a: float = float(_wanted.get(a, {"distance": INF})["distance"])
        var distance_b: float = float(_wanted.get(b, {"distance": INF})["distance"])
        return distance_a < distance_b
    )

    var applied: int = 0
    var apply_started_usec: int = Time.get_ticks_usec()
    for coord in coords:
        if applied >= max_mesh_applies_per_frame:
            break
        # Always allow one upload; later uploads obey a soft main-thread budget.
        if applied > 0 and Time.get_ticks_usec() - apply_started_usec >= int(max_mesh_apply_time_ms * 1000.0):
            break
        if not _completed_jobs.has(coord):
            continue
        var record: Dictionary = _completed_jobs[coord]
        if not _job_record_matches_current(record, coord):
            _completed_jobs.erase(coord)
            _stale_result_count += 1
            if _wanted.has(coord):
                var retry: Dictionary = _wanted[coord].duplicate(true)
                retry["queued_usec"] = Time.get_ticks_usec()
                _queued[coord] = retry
            continue

        _completed_jobs.erase(coord)
        var chunk: VoxelTerrainChunk = _chunks.get(coord) as VoxelTerrainChunk
        if chunk == null:
            chunk = ChunkScript.new()
            chunk.name = "VoxelChunk_%d_%d" % [coord.x, coord.y]
            add_child(chunk)
            _chunks[coord] = chunk
        _record_timing(
            _apply_wait_usec_samples,
            Time.get_ticks_usec() - int(record.get("completed_usec", Time.get_ticks_usec())),
            128
        )
        chunk.apply_mesh_data(record["data"], _voxel_material)
        _update_chunk_skirt_visibility(coord, chunk)
        _update_neighbor_chunk_skirts(coord)
        applied += 1



func _job_record_matches_current(record: Dictionary, coord: Vector2i) -> bool:
    # The skirts make neighbour target LOD irrelevant to this mesh's validity.
    if int(record["epoch"]) != _generation_epoch or int(record["seed"]) != seed_value:
        return false
    if bool(record["debug"]) != _debug_lod_colors or not _wanted.has(coord):
        return false
    var current: Dictionary = _wanted[coord]
    var previous: Dictionary = record["request"]
    return int(current["lod"]) == int(previous["lod"]) and bool(current["collision"]) == bool(previous["collision"])

func _running_job_matches(coord: Vector2i, request: Dictionary) -> bool:
    if not _running_by_coord.has(coord):
        return false
    var record: Dictionary = _running_tasks.get(int(_running_by_coord[coord]), {})
    return not record.is_empty() and int(record["epoch"]) == _generation_epoch and int(record["seed"]) == seed_value and bool(record["debug"]) == _debug_lod_colors and int(record["request"]["lod"]) == int(request["lod"]) and bool(record["request"]["collision"]) == bool(request["collision"])

func _completed_job_matches(coord: Vector2i, request: Dictionary) -> bool:
    if not _completed_jobs.has(coord):
        return false
    var record: Dictionary = _completed_jobs[coord]
    return int(record["epoch"]) == _generation_epoch and int(record["seed"]) == seed_value and bool(record["debug"]) == _debug_lod_colors and int(record["request"]["lod"]) == int(request["lod"]) and bool(record["request"]["collision"]) == bool(request["collision"])

func _neighbor_lods_for(coord: Vector2i) -> Dictionary:
    # Neighbour target LOD is deterministic before a mesh is ready. Thus its value
    # does not depend on the order in which background tasks finish.
    return {
        "left": _target_lod_for_neighbor(coord + Vector2i(-1, 0)),
        "right": _target_lod_for_neighbor(coord + Vector2i(1, 0)),
        "north": _target_lod_for_neighbor(coord + Vector2i(0, -1)),
        "south": _target_lod_for_neighbor(coord + Vector2i(0, 1))
    }

func _target_lod_for_neighbor(neighbor_coord: Vector2i) -> int:
    if neighbor_coord.x < 0 or neighbor_coord.y < 0 or neighbor_coord.x >= _chunks_per_axis or neighbor_coord.y >= _chunks_per_axis:
        return -1
    if _wanted.has(neighbor_coord):
        return int(_wanted[neighbor_coord]["lod"])
    return _lod_for_coord(neighbor_coord, _player_xz())

func _chunk_center(coord: Vector2i) -> Vector2:
    var start_x: int = coord.x * _chunk_size_voxels
    var start_z: int = coord.y * _chunk_size_voxels
    var size_x: int = mini(_chunk_size_voxels, _world_size_voxels - start_x)
    var size_z: int = mini(_chunk_size_voxels, _world_size_voxels - start_z)
    return Vector2(
        _world_min_x + (float(start_x) + float(size_x) * 0.5) * VOXEL_SIZE,
        _world_min_z + (float(start_z) + float(size_z) * 0.5) * VOXEL_SIZE
    )

func _player_xz() -> Vector2:
    if _player == null:
        return Vector2.ZERO
    return Vector2(_player.global_position.x, _player.global_position.z)

func _lod_for_coord(coord: Vector2i, player_xz: Vector2) -> int:
    if coord.x < 0 or coord.y < 0 or coord.x >= _chunks_per_axis or coord.y >= _chunks_per_axis:
        return -1
    var center: Vector2 = _chunk_bounds(coord)["center"]
    var distance: float = center.distance_to(player_xz)
    var previous_lod: int = int(_lod_state_cache.get(coord, -1))
    var target_lod: int
    if previous_lod < 0:
        target_lod = _lod_for_distance(distance)
    else:
        target_lod = previous_lod
        while target_lod < 4 and distance > _lod_boundary_for(target_lod) + lod_hysteresis_m:
            target_lod += 1
        while target_lod > 0 and distance < _lod_boundary_for(target_lod - 1) - lod_hysteresis_m:
            target_lod -= 1
    _lod_state_cache[coord] = target_lod
    return target_lod

func _lod_boundary_for(lod_index: int) -> float:
    match lod_index:
        0: return lod0_distance_m
        1: return lod1_distance_m
        2: return lod2_distance_m
        3: return lod3_distance_m
        _: return INF

func _get_streaming_heading() -> Vector2:
    if _player == null:
        return Vector2(0.0, -1.0)

    var forward_3d: Vector3 = -_player.global_transform.basis.z
    var view_heading := Vector2(forward_3d.x, forward_3d.z)
    if view_heading.length_squared() > 0.0001:
        view_heading = view_heading.normalized()
    else:
        view_heading = Vector2(0.0, -1.0)

    var planar_velocity := Vector2(_player.velocity.x, _player.velocity.z)
    if planar_velocity.length_squared() > 1.0:
        # Bias towards the current view so a rapid turn reprioritises visible chunks,
        # while retaining some look-ahead in the direction of travel.
        return (view_heading * 0.65 + planar_velocity.normalized() * 0.35).normalized()
    return view_heading

func _deadline_priority(center: Vector2, request: Dictionary, player_xz: Vector2, heading: Vector2, velocity: Vector2) -> float:
    var offset: Vector2 = center - player_xz
    var speed: float = velocity.length()
    var lod_index: int = clampi(int(request["lod"]), 0, 4)
    var estimate_seconds: float = _estimated_lod_pipeline_usec(lod_index) / 1000000.0
    var priority: float
    if speed >= 2.0:
        var direction: Vector2 = velocity / speed
        var along_track: float = offset.dot(direction)
        var lateral: float = absf(offset.cross(direction))
        if along_track < -chunk_size_m * 0.5:
            # Behind the viewer is cache/backfill work, not an arrival deadline.
            priority = 2.0 + center.distance_to(player_xz) / speed + lateral * 0.02
        else:
            var eta: float = maxf(0.0, along_track - chunk_size_m * 0.5) / speed
            priority = eta - estimate_seconds + lateral / maxf(speed, 1.0) * 0.35
    else:
        priority = center.distance_to(player_xz) - maxf(0.0, offset.dot(heading)) * 0.30
    if lod_index == 0:
        priority -= 0.15
    elif lod_index == 1:
        priority -= 0.07
    if bool(request["collision"]):
        var nearest: float = float(request.get("nearest_distance", center.distance_to(player_xz)))
        priority -= clampf((collision_distance_m - nearest) / maxf(collision_distance_m, 1.0), 0.0, 1.0) * 0.35
    return priority

func _refresh_build_estimate_cache() -> void:
    for lod_index in range(_build_usec_by_lod.size()):
        var samples: Array = _build_usec_by_lod[lod_index]
        if not samples.is_empty():
            _build_p95_cached_usec[lod_index] = _p95_usec(samples)
    if not _refresh_usec_samples.is_empty():
        _refresh_p95_cached_usec = _p95_usec(_refresh_usec_samples)
    if not _queue_wait_usec_samples.is_empty():
        _queue_wait_p95_cached_usec = _p95_usec(_queue_wait_usec_samples)
    if not _apply_wait_usec_samples.is_empty():
        _apply_wait_p95_cached_usec = _p95_usec(_apply_wait_usec_samples)

func _effective_prediction_seconds() -> float:
    var measured_work_usec: float = _estimated_lod_pipeline_usec(0)
    # Include the refresh interval itself as well as measured refresh cost, because a
    # chunk can be queued just after the last streaming refresh.
    # The 4 s ceiling prevents one pathological queue sample from exploding the fine-LOD area.
    return maxf(streaming_prediction_seconds, minf(measured_work_usec / 1000000.0 + 0.25, 4.0))

func _estimated_lod_pipeline_usec(lod_index: int) -> float:
    return (
        _estimated_build_usec(lod_index)
        + _refresh_p95_cached_usec
        + _queue_wait_p95_cached_usec
        + _apply_wait_p95_cached_usec
        + streaming_refresh_interval_s * 1000000.0
    )

func _estimated_build_usec(lod_index: int) -> float:
    return _build_p95_cached_usec[clampi(lod_index, 0, 4)]

func _record_timing(samples: Array, value_usec: int, limit: int) -> void:
    samples.append(maxi(0, value_usec))
    while samples.size() > limit:
        samples.pop_front()

func _avg_ms(samples: Array) -> float:
    if samples.is_empty():
        return 0.0
    var sum_usec: float = 0.0
    for value in samples:
        sum_usec += float(value)
    return sum_usec / float(samples.size()) / 1000.0

func _p95_ms(samples: Array) -> float:
    return _p95_usec(samples) / 1000.0

func _p95_usec(samples: Array) -> float:
    if samples.is_empty():
        return 0.0
    var ordered: Array = samples.duplicate()
    ordered.sort()
    var index: int = clampi(int(ceil(float(ordered.size() - 1) * 0.95)), 0, ordered.size() - 1)
    return float(ordered[index])

func _retire_stale_resources() -> void:
    # Free at most one old render/physics node per frame, smoothing mesh-buffer destruction.
    for chunk_value in _chunks.values():
        var resident_chunk: VoxelTerrainChunk = chunk_value as VoxelTerrainChunk
        if resident_chunk.retire_one_old_node():
            return
    for stale_chunk in _retiring_chunks:
        if stale_chunk.retire_one_old_node():
            return
    if not _retiring_chunks.is_empty():
        var finished_chunk: VoxelTerrainChunk = _retiring_chunks.pop_front()
        finished_chunk.free()

func _place_player_on_surface() -> void:
    if _player == null:
        _startup_load_pending = false
        return
    var safe_surface_height: float = get_surface_height(0.0, 0.0)
    _player.global_position = Vector3(0.0, safe_surface_height + 2.5, 0.0)
    _player.velocity = Vector3.ZERO
    _startup_load_pending = false
    _player.set_physics_process(true)

func _exit_tree() -> void:
    # Detached retired meshes are not children any more; release their references explicitly.
    for chunk_value in _chunks.values():
        var chunk: VoxelTerrainChunk = chunk_value as VoxelTerrainChunk
        while chunk.retire_one_old_node():
            pass
    for stale_chunk in _retiring_chunks:
        while stale_chunk.retire_one_old_node():
            pass
        if is_instance_valid(stale_chunk):
            stale_chunk.free()
    _retiring_chunks.clear()

func _lod_for_distance(distance: float) -> int:
    if distance < lod0_distance_m:
        return 0
    if distance < lod1_distance_m:
        return 1
    if distance < lod2_distance_m:
        return 2
    if distance < lod3_distance_m:
        return 3
    return 4
