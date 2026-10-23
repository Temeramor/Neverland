# Neverland 0.1.0.5

Neverland is a procedural first-person landscape exploration prototype built with Godot 4.7.2. This branch integrates **VoxEn 0.3.5** for streamed block-voxel terrain while preserving Neverland's original menu, sky/time-of-day system, weather controls, player controller, desktop input, Android touch controls and flight mode.

## Changes in 0.1.0.5

- **Consistent real shadows:** removed the obsolete scene reference to the deleted shadow proxy. Every visible voxel LOD casts its own terrain shadows; broad mountain shadows therefore come directly from the same terrain meshes shown to the player.
- **Balanced face lighting:** environment ambient light is enabled, direct light no longer darkens faces solely because their normal points away from the light, and a subtle emission baseline keeps occluded texture colours readable. Shadow attenuation still applies, so this is not an unshadowed/emissive material.
- **LOD verification:** extended the hierarchy smoke test to check the sampling stride for all seven levels (0.2, 0.4, 0.8, 1.6, 3.2, 6.4 and 12.8 m), in addition to distance bands, tile footprints and map-edge clipping.
- **Adaptive height cache:** the height cache stays at 0.5 m for the two finest levels, then grows with the mesh sampling step for distant LODs. A 2048 m LOD6 tile now needs only about 170 × 170 height-cache samples rather than a 0.5 m grid with more than 4,000 samples per axis. Native C++ and GDScript meshers use the same adaptive rule.
- **Scene cleanup:** the world scene no longer references a separate shadow proxy that is not present in the repository.
- **Version:** `project.godot` and `VERSION` both report `0.1.0.5`.

## Changes in 0.1.0.4

- **Grass and flowers disabled:** the terrain adapter no longer creates the grass field or flower instances. Existing UI, sky and weather controls remain.
- **Terrain scale checked against `main`:** the original Neverland world is 10,000 world metres across. At that reference size, the mountain height/width ranges and seeded range construction stay in the same metre-scale as `main`; voxel size is used only to quantise heights and mesh geometry, not to multiply the landscape scale. If `world_size` is reduced, mountain lengths, widths and heights scale proportionally with the world.
- **Simpler rock pixels:** removed the broad mineral bands, secondary tint layers, chips, pitting and added vertical fissure overlay. The base Neverland pixel palette remains, with two scales of Voronoi cracks. Crack widths vary and their visibility fades through continuous noise so cracks appear/disappear gradually instead of ending with a hard mask.
- **Native build fix:** `native/SConstruct` now initialises SCons with `ENV=os.environ.copy()`, preserving environment variables from the shell/toolchain.
- **Hierarchical whole-world voxel LOD:** the finite 10 × 10 km map is covered by coarse LOD6 root tiles (up to 2048 m each) before the player appears. Roots recursively split into four smaller tiles as the player approaches. A parent remains visible until every required child mesh is ready, so detail improves progressively without exposing unloaded holes.
- **Distance bands:** LOD0 0–128 m; LOD1 128–256 m; LOD2 256–512 m; LOD3 512–1024 m; LOD4 1024–2048 m; LOD5 2048–4096 m; LOD6 beyond 4096 m. A 12 m hysteresis margin helps avoid rebuilding tiles repeatedly right on a boundary.
- **Geometric mesh sampling:** tile footprints grow from 32 m to 2048 m. Horizontal mesh sampling steps are 0.2, 0.4, 0.8, 1.6, 3.2, 6.4 and 12.8 m for LOD0–6, while terrain heights stay quantised to 10 cm and the voxel material retains its pixel palette. This keeps coarse full-map coverage much cheaper than detailed chunks.
- **Distance-adaptive material detail:** grass/soil pixels simplify gradually and rock Voronoi cracks fade away by 520 m; the shader stops evaluating detailed rock cracks at greater distances.
- **Voxel shadows and softer face lighting:** every visible LOD casts its own terrain shadows again. The voxel shader keeps direct illumination orientation-independent to soften the bright-top/dark-side band, while shadow attenuation, environment ambient light and a small emission baseline preserve mountain shadows without letting shadowed textures collapse toward black.
- **Mobile shader lighting:** per-pixel lighting is enabled on mobile so the flat-lit shader still samples the terrain shadows.
- **Version:** `project.godot` and `VERSION` both report `0.1.0.5`.

## Run

1. Open the project in **Godot 4.7.2** and let the editor import resources.
2. Press **F5**, then start a new game from the existing menu.
3. During loading, coarse LOD6 tiles are built across the whole map first. Nearby tiles are then refined through LOD0–5; control is enabled only after full coarse coverage and the spawn chunk/collision are ready.
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
- **Startup:** coarse LOD6 meshes cover the full map; tile parents stay visible until all required child meshes are ready. The player appears only after world coverage and the spawn collision are ready.
- **Far LOD cost:** coarse tiles increase both mesh stride and height-cache spacing, so the world-covering hierarchy does not allocate a detailed sub-metre height cache for distant terrain.
- **Shadows:** visible voxel meshes at all LOD levels cast real terrain shadows. Their mesh cell size grows with distance, limiting the cost of distant shadow casters. The shader softens top/side lighting contrast but retains `ATTENUATION`, ambient light and a subtle emission fill.
- **Terrain:** 10 cm logical voxel columns sample Neverland's existing height profile. Range dimensions use world metres and are not multiplied by the voxel size. Smaller worlds shrink their mountain ranges with the configured world size.
- **Rock shader:** original seeded pixel palette plus smoothly faded, variable-width Voronoi cracks; broad mineral strata and additional crack/chip layers are disabled.
- **Current limitation:** this is a height-column voxel landscape, not a full 3D voxel volume. It does not yet support enclosed caves, overhangs, arbitrary voxel edits or persistent voxel changes; those require volumetric occupancy/density, a 3D mesher and matching collision generation.

## Smoke test

With Godot 4.7.2 installed:

~~~sh
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/neverland_voxen_smoke_test.gd
godot --headless --path . --script res://tests/lod_hierarchy_smoke_test.gd
~~~

The terrain smoke test checks deterministic terrain, the mountain profile, terrain density, and proportional mountain scaling. The LOD hierarchy test checks all seven distance bands, tile footprint scaling, and edge truncation at the 10 km world boundary.

## Version history

### 0.1.0.5
- Removed the stale proxy scene reference; all visible voxel LODs cast real shadows.
- Softened the face-lighting contrast while retaining real shadow attenuation and ambient fill.
- Expanded the hierarchy smoke test to verify mesh sampling strides.
- Adapted native and GDScript height caches to the selected mesh stride, avoiding dense 0.5 m caches for kilometre-scale root tiles.

### 0.1.0.4
- Added hierarchical full-map voxel coverage and parent-fallback visibility while finer child tiles build.
- Set the seven requested distance bands and geometrically increasing sampling steps.
- Restored terrain shadow casting for all visible LODs and removed the separate shadow proxy.

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
