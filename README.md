# Neverland 0.1.0.3

Neverland is a procedural first-person landscape exploration prototype built with Godot 4.7.2. This branch integrates **VoxEn 0.3.5** for streamed block-voxel terrain while preserving Neverland's original menu, sky/time-of-day system, weather controls, player controller, desktop input, Android touch controls and flight mode.

## Changes in 0.1.0.3

- **Grass and flowers disabled:** the terrain adapter no longer creates the grass field or flower instances. Existing UI, sky and weather controls remain.
- **Terrain scale checked against `main`:** the original Neverland world is 10,000 world metres across. At that reference size, the mountain height/width ranges and seeded range construction stay in the same metre-scale as `main`; voxel size is used only to quantise heights and mesh geometry, not to multiply the landscape scale. If `world_size` is reduced, mountain lengths, widths and heights scale proportionally with the world.
- **Simpler rock pixels:** removed the broad mineral bands, secondary tint layers, chips, pitting and added vertical fissure overlay. The base Neverland pixel palette remains, with two scales of Voronoi cracks. Crack widths vary and their visibility fades through continuous noise so cracks appear/disappear gradually instead of ending with a hard mask.
- **Native build fix:** `native/SConstruct` now initialises SCons with `ENV=os.environ.copy()`, preserving environment variables from the shell/toolchain.
- **Long-distance voxel terrain:** render radius increased from 256 m to 1536 m. Larger 32 m chunks and two extra geometric LOD levels reduce far mesh density to 3.2 m and 6.4 m sampling beyond 512 m and 1024 m respectively.
- **Distance-adaptive material detail:** grass/soil pixels simplify gradually and rock Voronoi cracks fade away by 520 m; the shader stops evaluating detailed rock cracks at greater distances.
- **Flat-lit voxel faces:** visible voxel chunk meshes no longer cast individual block shadows. Their shader gives faces uniform direct illumination while retaining external shadow attenuation.
- **Broad terrain shadows:** an invisible 25 m-grid shadow-only heightfield is generated during loading and casts the major mountain silhouettes; it avoids the cost of every voxel chunk casting shadows.
- **Mobile shader lighting:** per-pixel lighting is enabled on mobile so the flat-lit shader still samples the terrain shadows.
- **Version:** `project.godot` and `VERSION` both report `0.1.0.3`.

## Run

1. Open the project in **Godot 4.7.2** and let the editor import resources.
2. Press **F5**, then start a new game from the existing menu.
3. The loading screen also builds a coarse invisible terrain shadow caster, then waits for the spawn chunk and its collision. Other terrain chunks continue streaming during gameplay.
4. Windows: WASD/arrows to move and mouse to look. Android: use the left-side touch joystick and drag on the right side to look. Double-tap the right half (or double-tap Space on desktop) to toggle flight.
5. Press **VOXEN DEBUG** to show/hide the runtime streaming, LOD, collision and task profiler. **F3** toggles diagnostic LOD colours; **R** regenerates the landscape with a new seed.

## Native library build

The repository contains GDExtension source files but **does not include compiled DLL/SO libraries**. Build locally for the target platform. If the extension is absent, the GDScript mesher fallback is selected, though the native library is recommended for performance.

Requirements: a C++ compiler/toolchain, Python 3.12+, SCons, the Godot 4.7.2 C++ bindings (`godot-cpp` 10.0.0-stable), and the Android NDK for Android builds.

From the project root:

~~~sh
git clone --depth 1 --branch 10.0.0-stable https://github.com/godotengine/godot-cpp.git native/godot-cpp
python -m pip install --upgrade scons
cd native
~~~

Linux x86-64:

~~~sh
scons platform=linux target=template_debug arch=x86_64
scons platform=linux target=template_release arch=x86_64
~~~

Windows x86-64 (run in a shell where the native compiler is configured):

~~~sh
scons platform=windows target=template_debug arch=x86_64
scons platform=windows target=template_release arch=x86_64
~~~

Android ARM64 (with Android NDK environment configured):

~~~sh
scons platform=android target=template_debug arch=arm64
scons platform=android target=template_release arch=arm64
~~~

The extension descriptor is at `bin/voxen_native.gdextension`; compiled outputs are expected under `bin/linux/`, `bin/windows/` and `bin/android/`. Do not commit generated libraries.

## Architecture

- **Native C++:** chunk mesh building, height-cache sampling, greedy top-face merging, exposed side faces, LOD skirts and collision-height data.
- **GDScript:** world streaming/scheduling, deadline priority, worker task lifecycle, applying Godot rendering/physics resources on the main thread, player controls, UI, sky/weather and generation orchestration.
- **Startup:** a 25 m-grid invisible shadow proxy is prepared on the loading screen; only the spawn voxel chunk and its collision are required before control is enabled.
- **Shadows:** visible voxel meshes do not cast block-by-block shadows. The shadow-only terrain proxy supplies broad mountain shadows, while the voxel shader keeps face lighting uniform but still receives those shadows.
- **Terrain:** 10 cm logical voxel columns sample Neverland's existing height profile. Range dimensions use world metres and are not multiplied by the voxel size. Smaller worlds shrink their mountain ranges with the configured world size.
- **Rock shader:** original seeded pixel palette plus smoothly faded, variable-width Voronoi cracks; broad mineral strata and additional crack/chip layers are disabled.
- **Current limitation:** this is a height-column voxel landscape, not a full 3D voxel volume. It does not yet support enclosed caves, overhangs, arbitrary voxel edits or persistent voxel changes; those require volumetric occupancy/density, a 3D mesher and matching collision generation.

## Smoke test

With Godot 4.7.2 installed:

~~~sh
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/neverland_voxen_smoke_test.gd
godot --headless --path . --script res://tests/terrain_shadow_proxy_smoke_test.gd
~~~

The terrain smoke test checks deterministic terrain, the mountain profile, terrain density, and proportional mountain scaling. The shadow-proxy test checks that the coarse full-world mesh is generated and configured as shadows-only.

## Version history

### 0.1.0.3
- Added a coarse shadow-only terrain mesh; visible voxel chunks no longer cast block-by-block shadows.
- Flattened voxel face lighting while preserving major terrain shadows.

### 0.1.0.2
- Extended voxel streaming to a 1536 m radius using larger chunks and LOD levels 0–6.
- Faded fine material pixels and expensive rock cracks at distance.

### 0.1.0.1
- Disabled procedural grass and flower generation.
- Preserved the reference landscape scale from Neverland/main and made range size follow smaller world dimensions.
- Simplified rock pixels and kept soft, variable Voronoi cracks.
- Fixed inherited environment handling in `native/SConstruct`.
