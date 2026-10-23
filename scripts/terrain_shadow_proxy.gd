extends Node3D
class_name TerrainShadowProxy

## A coarse, invisible terrain mesh that preserves broad mountain shadows without
## making every visible voxel chunk cast shadows onto every other voxel chunk.
const VOXEL_SIZE: float = 0.1
const SAMPLE_STEP_TARGET_M: float = 25.0
const VERTICAL_OFFSET_M: float = 1.0

var _mesh_instance: MeshInstance3D
var _build_progress: float = 0.0
var _build_serial: int = 0


func get_build_progress() -> float:
    return _build_progress


func generate(generator: VoxelTerrainGenerator, world_size_m: float) -> bool:
    _build_serial += 1
    var serial: int = _build_serial
    _build_progress = 0.0
    visible = false

    if is_instance_valid(_mesh_instance):
        remove_child(_mesh_instance)
        _mesh_instance.queue_free()
        _mesh_instance = null

    var cells: int = maxi(1, ceili(world_size_m / SAMPLE_STEP_TARGET_M))
    var step_m: float = world_size_m / float(cells)
    var row_width: int = cells + 1
    var sample_count: int = row_width * row_width
    var half_size: float = world_size_m * 0.5
    var heights := PackedFloat32Array()
    heights.resize(sample_count)

    # This is a shadow silhouette, not a visible surface. Sampling more coarsely
    # preserves broad mountain shadows while avoiding per-voxel shadow draw calls.
    for z in range(row_width):
        var world_z: float = float(z) * step_m - half_size
        var row_offset: int = z * row_width
        for x in range(row_width):
            var world_x: float = float(x) * step_m - half_size
            var height_m: float = generator.get_surface_height(world_x, world_z)
            heights[row_offset + x] = floor(height_m / VOXEL_SIZE) * VOXEL_SIZE - VERTICAL_OFFSET_M
        if z % 8 == 0:
            _build_progress = 0.35 * float(z + 1) / float(row_width)
            await get_tree().process_frame
            if serial != _build_serial:
                return false

    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    vertices.resize(sample_count)
    normals.resize(sample_count)
    for z in range(row_width):
        var world_z: float = float(z) * step_m - half_size
        var row_offset: int = z * row_width
        for x in range(row_width):
            var world_x: float = float(x) * step_m - half_size
            var index: int = row_offset + x
            vertices[index] = Vector3(world_x, heights[index], world_z)

            var left_index: int = row_offset + maxi(x - 1, 0)
            var right_index: int = row_offset + mini(x + 1, cells)
            var back_index: int = maxi(z - 1, 0) * row_width + x
            var front_index: int = mini(z + 1, cells) * row_width + x
            normals[index] = Vector3(
                heights[left_index] - heights[right_index],
                2.0 * step_m,
                heights[back_index] - heights[front_index]
            ).normalized()
        if z % 24 == 0:
            _build_progress = 0.35 + 0.25 * float(z + 1) / float(row_width)
            await get_tree().process_frame
            if serial != _build_serial:
                return false

    var indices := PackedInt32Array()
    indices.resize(cells * cells * 6)
    var cursor: int = 0
    for z in range(cells):
        for x in range(cells):
            var a: int = z * row_width + x
            var b: int = a + 1
            var c: int = a + row_width
            var d: int = c + 1
            indices[cursor] = a
            indices[cursor + 1] = b
            indices[cursor + 2] = c
            indices[cursor + 3] = b
            indices[cursor + 4] = d
            indices[cursor + 5] = c
            cursor += 6
        if z % 24 == 0:
            _build_progress = 0.60 + 0.35 * float(z + 1) / float(cells)
            await get_tree().process_frame
            if serial != _build_serial:
                return false

    if serial != _build_serial:
        return false

    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_INDEX] = indices
    var mesh := ArrayMesh.new()
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

    _mesh_instance = MeshInstance3D.new()
    _mesh_instance.name = "TerrainShadowCaster"
    _mesh_instance.mesh = mesh
    # Keep the caster invisible but let its coarse terrain silhouette cast the
    # sunlight shadows received by the visible voxel and far-landscape materials.
    _mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
    _mesh_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
    add_child(_mesh_instance)
    visible = true
    _build_progress = 1.0
    return true
