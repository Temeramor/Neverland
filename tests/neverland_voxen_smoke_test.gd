extends SceneTree

func _initialize() -> void:
    var generator_script := load("res://scripts/voxel_generator.gd")
    var first = generator_script.new(123456, 10000.0)
    var second = generator_script.new(123456, 10000.0)
    var half_size_world = generator_script.new(123456, 5000.0)
    var h0: float = first.get_surface_height(0.0, 0.0)
    var h1: float = second.get_surface_height(0.0, 0.0)
    assert(is_equal_approx(h0, h1), "Same seed should generate identical terrain.")
    assert(h0 >= 0.1, "Voxel surfaces must remain above the world floor.")
    assert(first.get_surface_height_voxels(0.0, 0.0) >= 1, "Surface voxel height should be positive.")
    assert(first.get_mountain_profile().size() == 9, "Three seeded mountain chains should create nine segments.")
    var original_profile: Array = first.get_mountain_profile()
    var half_profile: Array = half_size_world.get_mountain_profile()
    assert(is_equal_approx(float(original_profile[0]["width"]) * 0.5, float(half_profile[0]["width"])),
        "Half-size worlds should get half-width mountain ranges.")
    assert(is_equal_approx(float(original_profile[0]["height"]) * 0.5, float(half_profile[0]["height"])),
        "Half-size worlds should get half-height mountain ranges.")
    assert(first.get_terrain_density(0.0, h0 - 1.0, 0.0) > 0.0, "Below the surface must be solid.")
    assert(first.get_terrain_density(0.0, h0 + 1.0, 0.0) < 0.0, "Above the surface must be air.")
    print("Neverland/VoxEn smoke test passed. spawn_height=%.2f" % h0)
    quit()
