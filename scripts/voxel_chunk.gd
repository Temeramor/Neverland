extends Node3D
class_name VoxelTerrainChunk

## Holds render/collision resources for one chunk. Mesh CPU work happens in VoxelChunkMeshBuilder;
## replacements are attached on the main thread and old GPU-backed nodes are retired gradually.

const VOXEL_SIZE: float = 0.1
const BuilderScript = preload("res://scripts/voxel_chunk_builder.gd")

var coord: Vector2i = Vector2i.ZERO
var lod: int = -1
var collision_enabled: bool = false # A collision shape is allocated for this chunk.
var collision_active: bool = false # Its collision layer is currently enabled.
var mesh_ready: bool = false
var debug_lod_colors: bool = false
var neighbor_lods_used: Dictionary = {}

var _render_active: bool = true
var _skirt_visibility_cache := Vector4(-1.0, -1.0, -1.0, -1.0)
# Use a unique regular ShaderMaterial per chunk instead of instance uniforms.
# Compatibility renderer hardware can impose a very low per-instance-uniform limit.
var _mesh_shader_material: ShaderMaterial
var _retired_nodes: Array[Node] = []

# Convenient synchronous entry point for small tests. Runtime streaming uses WorkerThreadPool.
func build(
    p_coord: Vector2i,
    start_voxel_x: int,
    start_voxel_z: int,
    size_voxels_x: int,
    size_voxels_z: int,
    p_lod: int,
    neighbor_lods: Dictionary,
    generator: VoxelTerrainGenerator,
    material: Material,
    world_min_x: float,
    world_min_z: float,
    world_size_voxels: int,
    want_collision: bool,
    p_debug_lod_colors: bool
) -> void:
    var job_data := {
        "coord": p_coord,
        "request": {
            "lod": p_lod,
            "start_x": start_voxel_x,
            "start_z": start_voxel_z,
            "size_x": size_voxels_x,
            "size_z": size_voxels_z,
            "collision": want_collision,
            "distance": 0.0,
            "priority": 0.0
        },
        "neighbor_lods": neighbor_lods.duplicate(true),
        "seed": generator.seed_value,
        "world_min_x": world_min_x,
        "world_min_z": world_min_z,
        "world_size_voxels": world_size_voxels,
        "debug_lod_colors": p_debug_lod_colors
    }
    var builder = BuilderScript.new()
    apply_mesh_data(builder.build_mesh_data(job_data), material)

func apply_mesh_data(data: Dictionary, material: Material) -> void:
    # Collision is based on world height, not visual LOD. Preserve an existing heightmap body
    # when only the render mesh changes so visual streaming does not churn physics resources.
    var wants_collision: bool = bool(data.get("want_collision", false))
    var collision_body := get_node_or_null("VoxelCollision") as StaticBody3D
    var preserve_collision: bool = wants_collision and collision_enabled and collision_body != null
    _retire_current_generation(preserve_collision)
    _mesh_shader_material = null
    coord = data.get("coord", Vector2i.ZERO)
    lod = int(data.get("lod", -1))
    debug_lod_colors = bool(data.get("debug_lod_colors", false))
    neighbor_lods_used = data.get("neighbor_lods_used", {}).duplicate(true)
    collision_enabled = false
    collision_active = false
    position = data.get("position", Vector3.ZERO)
    mesh_ready = false
    if preserve_collision:
        collision_enabled = true
        set_collision_active(_render_active and wants_collision)
    else:
        collision_enabled = false
        collision_active = false

    if not bool(data.get("has_geometry", false)):
        return

    # Instance uniforms reserve a fixed per-node buffer on the Compatibility renderer.
    # A regular uniform on a per-chunk material avoids exhausting that hardware-limited buffer.
    var mesh_material: Material = material
    if material is ShaderMaterial:
        _mesh_shader_material = (material as ShaderMaterial).duplicate() as ShaderMaterial
        _mesh_shader_material.set_shader_parameter("skirt_visibility", Vector4(1.0, 1.0, 1.0, 1.0))
        mesh_material = _mesh_shader_material

    var mesh := _make_array_mesh(data, mesh_material)
    mesh.resource_name = "VoxelChunk_%d_%d_LOD%d" % [coord.x, coord.y, lod]
    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "VoxelMesh"
    mesh_instance.mesh = mesh
    # Fine and nearby voxel terrain casts real shadows. Far LODs use the shared coarse
    # terrain shadow proxy, avoiding expensive shadow rendering for the whole 10 km map.
    mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if lod <= 2 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _skirt_visibility_cache = Vector4(-1.0, -1.0, -1.0, -1.0)
    add_child(mesh_instance)
    mesh_ready = true

    if wants_collision and not preserve_collision:
        var collision_data: Dictionary = data.get("collision_height_map", {})
        if not collision_data.is_empty():
            var height_shape := HeightMapShape3D.new()
            height_shape.map_width = int(collision_data["width"])
            height_shape.map_depth = int(collision_data["depth"])
            height_shape.map_data = collision_data["heights"]

            var collision_shape := CollisionShape3D.new()
            collision_shape.name = "VoxelCollisionShape"
            collision_shape.shape = height_shape
            var step_m: float = float(collision_data.get("step_m", 0.2))
            collision_shape.scale = Vector3(step_m, step_m, step_m)
            collision_shape.position = Vector3(
                float(int(collision_data["width"]) - 1) * step_m * 0.5,
                0.0,
                float(int(collision_data["depth"]) - 1) * step_m * 0.5
            )

            var body := StaticBody3D.new()
            body.name = "VoxelCollision"
            var should_collide: bool = _render_active and bool(data.get("want_collision", false))
            body.collision_layer = 1 if should_collide else 0
            body.collision_mask = 1 if should_collide else 0
            body.add_child(collision_shape)
            add_child(body)
            collision_enabled = true
            collision_active = should_collide

func set_render_active(active: bool, request_collision: bool = false) -> void:
    # Refresh visits hundreds of resident chunks. Do not walk child nodes unless
    # render visibility actually changes; collision state is handled independently.
    var render_state_changed: bool = _render_active != active
    _render_active = active
    if render_state_changed:
        for child in get_children():
            if child is VisualInstance3D:
                child.visible = active

    var wants_active_collision: bool = active and request_collision and collision_enabled
    if collision_active != wants_active_collision:
        set_collision_active(wants_active_collision)

func set_skirt_visibility(visibility: Vector4) -> void:
    if _skirt_visibility_cache.is_equal_approx(visibility):
        return
    _skirt_visibility_cache = visibility
    if _mesh_shader_material != null:
        _mesh_shader_material.set_shader_parameter("skirt_visibility", visibility)

func set_collision_active(active: bool) -> void:
    collision_active = active and collision_enabled and _render_active
    for child in get_children():
        if child is StaticBody3D and child.name == "VoxelCollision":
            child.collision_layer = 1 if collision_active else 0
            child.collision_mask = 1 if collision_active else 0

func retire_one_old_node() -> bool:
    if _retired_nodes.is_empty():
        return false
    var old_node: Node = _retired_nodes.pop_front()
    old_node.free()
    return true

func _retire_current_generation(preserve_collision: bool = false) -> void:
    mesh_ready = false
    for child in get_children():
        if preserve_collision and child is StaticBody3D and child.name == "VoxelCollision":
            continue
        if child is StaticBody3D:
            child.collision_layer = 0
            child.collision_mask = 0
        if child is VisualInstance3D:
            child.visible = false
        remove_child(child)
        _retired_nodes.append(child)
    if not preserve_collision:
        collision_enabled = false
        collision_active = false

func _make_array_mesh(data: Dictionary, material: Material) -> ArrayMesh:
    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = data["vertices"]
    arrays[Mesh.ARRAY_NORMAL] = data["normals"]
    arrays[Mesh.ARRAY_COLOR] = data["colors"]
    arrays[Mesh.ARRAY_INDEX] = data["indices"]
    var mesh := ArrayMesh.new()
    if not data["indices"].is_empty():
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        if material != null:
            mesh.surface_set_material(0, material)
    return mesh

