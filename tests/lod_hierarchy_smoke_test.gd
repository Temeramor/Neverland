extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var world := VoxelWorld.new()
    world.auto_start_on_ready = false
    world.world_size_m = 10000.0
    world.chunk_size_m = 32.0
    root.add_child(world)
    await process_frame

    var errors: Array[String] = []

    # Regression test: a leaf LOD has no children, so visibility reconciliation
    # must safely handle the typed empty Array[Vector2i] path.
    var leaf_key: Vector2i = world._make_lod_key(0, 0, 0)
    world._wanted[leaf_key] = {"lod": 0, "fallback": false, "collision": false}
    world._update_lod_subtree_visibility(leaf_key, true)
    world._wanted.erase(leaf_key)

    var samples: Array = [
        [0.0, 0], [127.9, 0],
        [128.0, 1], [255.9, 1],
        [256.0, 2], [511.9, 2],
        [512.0, 3], [1023.9, 3],
        [1024.0, 4], [2047.9, 4],
        [2048.0, 5], [4095.9, 5],
        [4096.0, 6]
    ]
    for sample in samples:
        var distance: float = float(sample[0])
        var expected_lod: int = int(sample[1])
        if world._lod_for_distance(distance) != expected_lod:
            errors.append("Default LOD distance %.1f m expected LOD%d, got LOD%d" % [
                distance, expected_lod, world._lod_for_distance(distance)
            ])

    # Every boundary follows a single LOD0 distance and doubles at the next level.
    world.set_lod_settings(1, 64.0)
    var scaled_samples: Array = [
        [0.0, 0], [63.9, 0], [64.0, 1],
        [127.9, 1], [128.0, 2], [255.9, 2],
        [256.0, 3], [511.9, 3], [512.0, 4],
        [1023.9, 4], [1024.0, 5], [2047.9, 5],
        [2048.0, 6]
    ]
    for sample in scaled_samples:
        var distance: float = float(sample[0])
        var expected_lod: int = int(sample[1])
        if world._lod_for_distance(distance) != expected_lod:
            errors.append("Scaled LOD distance %.1f m expected LOD%d, got LOD%d" % [
                distance, expected_lod, world._lod_for_distance(distance)
            ])
    world.set_lod_settings(1, 128.0)

    var expected_tile_sizes: Array[float] = [32.0, 64.0, 128.0, 256.0, 512.0, 1024.0, 2048.0]
    for lod in range(7):
        var key: Vector2i = world._make_lod_key(lod, 0, 0)
        var bounds: Dictionary = world._chunk_bounds(key)
        var expected_size: float = expected_tile_sizes[lod]
        if not is_equal_approx(float(bounds["width"]), expected_size):
            errors.append("LOD%d tile width expected %.1f m, got %.1f m" % [
                lod, expected_size, float(bounds["width"])
            ])

    var expected_steps_voxels: Array[int] = [2, 8, 16, 32, 64, 128, 256]
    for lod in range(7):
        var requested: Dictionary = {}
        world._collect_lod_tiles(
            lod, 0, 0,
            Vector2(5000.0, 5000.0), Vector2(0.0, -1.0), Vector2.ZERO,
            requested
        )
        var key: Vector2i = world._make_lod_key(lod, 0, 0)
        var actual_step: int = int(requested[key]["step_voxels"])
        if actual_step != expected_steps_voxels[lod]:
            errors.append("Coarse default LOD%d stride expected %d voxels, got %d" % [
                lod, expected_steps_voxels[lod], actual_step
            ])

    world.set_lod_settings(0, 128.0)
    var standard_steps: Array[int] = [2, 4, 8, 16, 32, 64, 128]
    for lod in range(7):
        var actual_step: int = world.get_mesh_step_voxels(lod)
        if actual_step != standard_steps[lod]:
            errors.append("Standard LOD%d stride expected %d voxels, got %d" % [
                lod, standard_steps[lod], actual_step
            ])
    world.set_lod_settings(1, 128.0)

    var root_count: int = ceili(float(world._world_size_voxels) / float(world._chunk_size_voxels * 64))
    if root_count != 5:
        errors.append("10 km map should need 5 LOD6 roots per axis, got %d" % root_count)
    var last_root := world._chunk_bounds(world._make_lod_key(6, 4, 4))
    if not is_equal_approx(float(last_root["width"]), 1808.0):
        errors.append("Last edge tile should be clipped to 1808 m, got %.1f m" % float(last_root["width"]))

    world.queue_free()
    await process_frame
    if errors.is_empty():
        print("Neverland LOD hierarchy smoke test passed.")
        quit(0)
    else:
        for error_text in errors:
            push_error(error_text)
        quit(1)
