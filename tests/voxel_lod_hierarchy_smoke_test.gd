extends SceneTree

const WorldScript = preload("res://scripts/voxel_world.gd")
var _failed: bool = false


func _initialize() -> void:
    call_deferred("_run_test")


func _expect(condition: bool, message: String) -> void:
    if not condition:
        _failed = true
        push_error(message)


func _run_test() -> void:
    var world = WorldScript.new()
    world.auto_start_on_ready = false
    root.add_child(world)
    await process_frame

    _expect(world._lod_for_distance(127.99) == 0, "0-128m should use LOD0.")
    _expect(world._lod_for_distance(128.0) == 1, "128m should switch to LOD1.")
    _expect(world._lod_for_distance(256.0) == 2, "256m should switch to LOD2.")
    _expect(world._lod_for_distance(512.0) == 3, "512m should switch to LOD3.")
    _expect(world._lod_for_distance(1024.0) == 4, "1024m should switch to LOD4.")
    _expect(world._lod_for_distance(2048.0) == 5, "2048m should switch to LOD5.")
    _expect(world._lod_for_distance(4096.0) == 6, "4096m should switch to LOD6.")

    var far_bounds: Dictionary = world._chunk_bounds(world._make_lod_key(6, 0, 0))
    _expect(is_equal_approx(float(far_bounds["width"]), 2048.0), "LOD6 root tiles should cover 2048m.")

    var l4: Dictionary = {}
    world._collect_lod_tiles(4, 0, 0, Vector2(-4500.0, -4500.0), Vector2(0.0, -1.0), Vector2.ZERO, l4)
    _expect(int(l4[world._make_lod_key(4, 0, 0)]["step_voxels"]) == 32, "LOD4 stride should be 3.2m.")
    var l5: Dictionary = {}
    world._collect_lod_tiles(5, 0, 0, Vector2(-4500.0, -4500.0), Vector2(0.0, -1.0), Vector2.ZERO, l5)
    _expect(int(l5[world._make_lod_key(5, 0, 0)]["step_voxels"]) == 64, "LOD5 stride should be 6.4m.")
    var l6: Dictionary = {}
    world._collect_lod_tiles(6, 0, 0, Vector2.ZERO, Vector2(0.0, -1.0), Vector2.ZERO, l6)
    _expect(int(l6[world._make_lod_key(6, 0, 0)]["step_voxels"]) == 128, "LOD6 stride should be 12.8m.")
    _expect(not world.is_world_coverage_ready(), "Coverage must not report ready before root meshes exist.")

    world.queue_free()
    await process_frame
    if _failed:
        push_error("Neverland hierarchical LOD smoke test failed.")
        quit(1)
    else:
        print("Neverland hierarchical LOD smoke test passed.")
        quit()
