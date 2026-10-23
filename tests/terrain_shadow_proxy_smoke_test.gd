extends SceneTree

func _initialize() -> void:
    call_deferred("_run_test")


func _run_test() -> void:
    var generator_script = load("res://scripts/voxel_generator.gd")
    var proxy_script = load("res://scripts/terrain_shadow_proxy.gd")
    var generator = generator_script.new(123456, 400.0)
    var proxy = proxy_script.new()
    root.add_child(proxy)

    var completed: bool = await proxy.generate(generator, 400.0)
    assert(completed, "Shadow proxy generation should complete.")
    assert(is_equal_approx(proxy.get_build_progress(), 1.0), "Shadow proxy progress should reach 100%.")
    assert(proxy.visible, "The proxy node must be enabled so Godot can render its shadows.")
    assert(proxy.get_child_count() == 1, "Expected one invisible shadow-casting mesh.")

    var caster: MeshInstance3D = proxy.get_child(0) as MeshInstance3D
    assert(caster != null and caster.mesh != null, "Shadow caster mesh should be built.")
    assert(caster.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY,
        "The shadow proxy must only render shadows, not visible pixels.")
    assert(caster.mesh.get_surface_count() == 1, "Expected one coarse mesh surface.")
    assert(caster.mesh.get_aabb().size.x > 399.0, "Proxy should cover the requested world width.")
    print("Terrain shadow proxy smoke test passed.")
    quit()
