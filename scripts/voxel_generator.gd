extends RefCounted
class_name VoxelTerrainGenerator

## Neverland terrain profile sampled as 10 cm voxel columns.
## Chunk meshing is streamed; no world-sized height array or per-voxel Node allocation is used.

const VOXEL_SIZE: float = 0.1
const AIR: int = 0
const GRASS: int = 1
const SOIL: int = 2
const ROCK: int = 3
const MIN_TERRAIN_HEIGHT: float = -80.0
const MAX_TERRAIN_HEIGHT: float = 1600.0
const HEIGHT_SAMPLE_STEP_M: float = 0.5
const MAX_SURFACE_CACHE_ENTRIES: int = 131072
const REFERENCE_WORLD_SIZE_M: float = 10000.0

var seed_value: int = 1337
var world_size_m: float = 10000.0
var _macro_noise: FastNoiseLite
var _hill_noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _ridge_noise: FastNoiseLite
var _micro_ridge_noise: FastNoiseLite
var _transition_noise: FastNoiseLite
var _mountain_starts: Array[Vector2] = []
var _mountain_deltas: Array[Vector2] = []
var _mountain_lengths_squared: Array[float] = []
var _mountain_widths: Array[float] = []
var _mountain_heights: Array[float] = []
var _mountain_phases: Array[float] = []
var _surface_height_cache: Dictionary = {}


func _init(p_seed: int = 1337, p_world_size_m: float = 10000.0) -> void:
    seed_value = p_seed
    world_size_m = maxf(256.0, p_world_size_m)
    _create_noise_fields()
    _create_mountain_ranges()


func _make_noise(noise_seed: int, frequency_value: float, octave_count: int, fractal_mode: FastNoiseLite.FractalType) -> FastNoiseLite:
    var noise := FastNoiseLite.new()
    noise.seed = noise_seed
    noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
    noise.frequency = frequency_value
    noise.fractal_type = fractal_mode
    noise.fractal_octaves = octave_count
    noise.fractal_lacunarity = 2.05
    noise.fractal_gain = 0.52
    return noise


func _create_noise_fields() -> void:
    _macro_noise = _make_noise(seed_value + 101, 0.00028, 4, FastNoiseLite.FRACTAL_FBM)
    _hill_noise = _make_noise(seed_value + 307, 0.00115, 4, FastNoiseLite.FRACTAL_FBM)
    _detail_noise = _make_noise(seed_value + 503, 0.0048, 3, FastNoiseLite.FRACTAL_FBM)
    _ridge_noise = _make_noise(seed_value + 709, 0.00082, 5, FastNoiseLite.FRACTAL_RIDGED)
    _micro_ridge_noise = _make_noise(seed_value + 907, 0.0034, 3, FastNoiseLite.FRACTAL_RIDGED)
    _transition_noise = _make_noise(seed_value + 1301, 0.008, 2, FastNoiseLite.FRACTAL_FBM)


func _create_mountain_ranges() -> void:
    _mountain_starts.clear()
    _mountain_deltas.clear()
    _mountain_lengths_squared.clear()
    _mountain_widths.clear()
    _mountain_heights.clear()
    _mountain_phases.clear()
    var rng := RandomNumberGenerator.new()
    rng.seed = int(seed_value) + 17011
    for _range_index in range(3):
        var angle: float = rng.randf_range(0.0, PI)
        var direction := Vector2(cos(angle), sin(angle))
        var side := Vector2(-direction.y, direction.x)
        var center := Vector2(
            rng.randf_range(-world_size_m * 0.20, world_size_m * 0.20),
            rng.randf_range(-world_size_m * 0.20, world_size_m * 0.20)
        )
        var half_length: float = world_size_m * rng.randf_range(0.23, 0.34)
        var points: Array[Vector2] = [
            center - direction * half_length + side * rng.randf_range(-600.0, 600.0),
            center - direction * half_length * 0.34 + side * rng.randf_range(-1050.0, 1050.0),
            center + direction * half_length * 0.30 + side * rng.randf_range(-1050.0, 1050.0),
            center + direction * half_length + side * rng.randf_range(-600.0, 600.0)
        ]
        # The source project defines these dimensions in world metres, not voxel counts.
        # The 10 km reference keeps Neverland/main's exact mountain scale; smaller maps
        # proportionally shrink mountain height and width instead of producing huge peaks.
        var mountain_scale: float = world_size_m / REFERENCE_WORLD_SIZE_M
        var range_height: float = rng.randf_range(850.0, 1320.0) * mountain_scale
        var range_width: float = rng.randf_range(540.0, 930.0) * mountain_scale
        var phase: float = rng.randf_range(0.0, TAU)
        for segment_index in range(points.size() - 1):
            var a: Vector2 = points[segment_index]
            var b: Vector2 = points[segment_index + 1]
            var delta: Vector2 = b - a
            _mountain_starts.append(a)
            _mountain_deltas.append(delta)
            _mountain_lengths_squared.append(maxf(delta.length_squared(), 0.001))
            _mountain_widths.append(range_width * rng.randf_range(0.88, 1.12))
            _mountain_heights.append(range_height * rng.randf_range(0.94, 1.06))
            _mountain_phases.append(phase + float(segment_index) * 1.7)


func get_mountain_profile() -> Array[Dictionary]:
    var profile: Array[Dictionary] = []
    for i in range(_mountain_starts.size()):
        profile.append({
            "start": _mountain_starts[i], "delta": _mountain_deltas[i],
            "length_squared": _mountain_lengths_squared[i], "width": _mountain_widths[i],
            "height": _mountain_heights[i], "phase": _mountain_phases[i]
        })
    return profile


func get_surface_height(x: float, z: float) -> float:
    var grid_x: int = roundi(x / HEIGHT_SAMPLE_STEP_M)
    var grid_z: int = roundi(z / HEIGHT_SAMPLE_STEP_M)
    if absf(x - float(grid_x) * HEIGHT_SAMPLE_STEP_M) < 0.0001 and absf(z - float(grid_z) * HEIGHT_SAMPLE_STEP_M) < 0.0001:
        return _get_cached_grid_height(grid_x, grid_z)
    return _calculate_surface_height(x, z)


func get_surface_sample(x: float, z: float) -> Vector3:
    # Bilinear sample the same half-metre height lattice used by voxel mesh jobs.
    # This keeps the original vegetation API inexpensive without a giant height map.
    var grid_x_float: float = x / HEIGHT_SAMPLE_STEP_M
    var grid_z_float: float = z / HEIGHT_SAMPLE_STEP_M
    var grid_x: int = floori(grid_x_float)
    var grid_z: int = floori(grid_z_float)
    var tx: float = clampf(grid_x_float - float(grid_x), 0.0, 1.0)
    var tz: float = clampf(grid_z_float - float(grid_z), 0.0, 1.0)
    var h00: float = _get_cached_grid_height(grid_x, grid_z)
    var h10: float = _get_cached_grid_height(grid_x + 1, grid_z)
    var h01: float = _get_cached_grid_height(grid_x, grid_z + 1)
    var h11: float = _get_cached_grid_height(grid_x + 1, grid_z + 1)
    var top: float = lerpf(h00, h10, tx)
    var bottom: float = lerpf(h01, h11, tx)
    var height: float = lerpf(top, bottom, tz)
    var slope_x: float = lerpf(h10 - h00, h11 - h01, tz) / HEIGHT_SAMPLE_STEP_M
    var slope_z: float = lerpf(h01 - h00, h11 - h10, tx) / HEIGHT_SAMPLE_STEP_M
    return Vector3(height, slope_x, slope_z)


func _get_cached_grid_height(grid_x: int, grid_z: int) -> float:
    var key := Vector2i(grid_x, grid_z)
    if _surface_height_cache.has(key):
        return float(_surface_height_cache[key])
    if _surface_height_cache.size() >= MAX_SURFACE_CACHE_ENTRIES:
        _surface_height_cache.clear()
    var x: float = float(grid_x) * HEIGHT_SAMPLE_STEP_M
    var z: float = float(grid_z) * HEIGHT_SAMPLE_STEP_M
    var height: float = _calculate_surface_height(x, z)
    _surface_height_cache[key] = height
    return height


func _calculate_surface_height(x: float, z: float) -> float:
    var macro: float = _macro_noise.get_noise_2d(x, z)
    var hills: float = _hill_noise.get_noise_2d(x, z)
    var detail: float = _detail_noise.get_noise_2d(x, z)
    var ridge_detail: float = (_ridge_noise.get_noise_2d(x, z) + 1.0) * 0.5
    var micro_ridge: float = _micro_ridge_noise.get_noise_2d(x, z)
    var height: float = 26.0 + macro * 17.0 + hills * 10.0
    height += maxf(hills - 0.12, 0.0) * 18.0
    height += detail * 3.8
    var mountain_height: float = 0.0
    var point := Vector2(x, z)
    for segment_index in range(_mountain_starts.size()):
        var a: Vector2 = _mountain_starts[segment_index]
        var ab: Vector2 = _mountain_deltas[segment_index]
        var length_squared: float = _mountain_lengths_squared[segment_index]
        var along: float = clampf((point - a).dot(ab) / length_squared, 0.0, 1.0)
        var closest: Vector2 = a + ab * along
        var offset: Vector2 = point - closest
        var distance_squared: float = offset.length_squared()
        var width: float = _mountain_widths[segment_index]
        var broad_radius: float = width * 1.72
        if distance_squared >= broad_radius * broad_radius:
            continue
        var distance: float = sqrt(distance_squared)
        var peak_height: float = _mountain_heights[segment_index]
        var phase: float = _mountain_phases[segment_index]
        var broad_mask: float = clampf(1.0 - distance / broad_radius, 0.0, 1.0)
        var cliff_mask: float = clampf(1.0 - distance / width, 0.0, 1.0)
        var crest_profile: float = 0.77 + 0.23 * absf(sin(along * PI * 2.1 + phase))
        var rough_profile: float = 0.79 + 0.21 * ridge_detail
        var foothills: float = pow(broad_mask, 1.28) * (peak_height * 0.39 + 75.0)
        var crest: float = pow(cliff_mask, 0.94) * peak_height * crest_profile * rough_profile
        mountain_height = maxf(mountain_height, maxf(foothills, crest))
    height += mountain_height
    if mountain_height > 1.0:
        var mountain_mask: float = clampf(mountain_height / 900.0, 0.0, 1.0)
        height += mountain_mask * (micro_ridge * 34.0 + detail * 22.0)
    var spawn_fade: float = 1.0 - _smoothstep(420.0, 1420.0, point.length())
    var spawn_height: float = 25.0 + macro * 3.0 + detail * 0.8
    height = lerpf(height, spawn_height, spawn_fade)
    # Column meshing starts at Y=0; preserve the profile while ensuring at least one voxel of ground.
    return maxf(VOXEL_SIZE, clampf(height, MIN_TERRAIN_HEIGHT, MAX_TERRAIN_HEIGHT))


func _smoothstep(edge_a: float, edge_b: float, value: float) -> float:
    var t: float = clampf((value - edge_a) / (edge_b - edge_a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


func get_surface_height_voxels(x: float, z: float) -> int:
    return maxi(1, int(round(get_surface_height(x, z) / VOXEL_SIZE)))


func get_surface_material(height_m: float, slope: float, x: float, z: float) -> int:
    # Match Neverland's grass-to-stone transition: slope, not elevation, determines rock.
    # At voxel scale a single material is chosen per column, so the original smooth colour
    # blend becomes a fine seeded transition across 10 cm columns.
    var transition_noise: float = _transition_noise.get_noise_2d(x, z) * 0.05
    return ROCK if slope + transition_noise >= 0.39 else GRASS


func get_terrain_density(world_x: float, world_y: float, world_z: float) -> float:
    return get_surface_height(world_x, world_z) - world_y


func get_voxel_material(voxel: Vector3i, world_min_x: float, world_min_z: float, world_size_voxels: int) -> int:
    if voxel.x < 0 or voxel.z < 0 or voxel.x >= world_size_voxels or voxel.z >= world_size_voxels or voxel.y < 0:
        return AIR
    var world_x: float = world_min_x + (float(voxel.x) + 0.5) * VOXEL_SIZE
    var world_z: float = world_min_z + (float(voxel.z) + 0.5) * VOXEL_SIZE
    var surface_y: int = get_surface_height_voxels(world_x, world_z)
    if voxel.y >= surface_y:
        return AIR
    if voxel.y == surface_y - 1:
        return get_surface_material(float(surface_y) * VOXEL_SIZE, 0.0, world_x, world_z)
    if voxel.y >= surface_y - 5:
        return SOIL
    return ROCK
