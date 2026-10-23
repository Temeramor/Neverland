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
            errors.append("Distance %.1f m expected LOD%d, got LOD%d" % [
                distance, expected_lod, world._lod_for_distance(distance)
            ])

    var expected_tile_sizes: Array[float] = [32.0, 64.0, 128.0, 256.0, 512.0, 1024.0, 2048.0]
    for lod in range(7):
        var key: Vector2i = world._make_lod_key(lod, 0, 0)
        var bounds: Dictionary = world._chunk_bounds(key)
        var expected_size: float = expected_tile_sizes[lod]
        if not is_equal_approx(float(bounds["width"]), expected_size):
            errors.append("LOD%d tile width expected %.1f m, got %.1f m" % [
                lod, expected_size, float(bounds["width"])
            ])

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
