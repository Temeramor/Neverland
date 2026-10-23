# Neverland 0.1.0

Neverland is a procedural first-person landscape exploration prototype built with Godot 4.7.2. This branch integrates **VoxEn 0.3.5** for block-voxel terrain while preserving Neverland's menu, sky/time-of-day system, weather controls, player controller, desktop input, Android touch joystick and look gestures, flight mode, grass and flowers.

## What changed

- **Voxel terrain:** the original Neverland terrain profile is retained: broad rolling terrain, three seeded mountain ranges, noisy ridges and the softened spawn area. The profile is sampled onto a 10 cm voxel grid.
- **Consistent pixel colouring:** the terrain shader uses Neverland's seeded grass, soil and rock palette. Colour cells are aligned to 0.1 m voxels and sampled from just inside each voxel, so its top and side faces use the same seeded colour cell.
- **Chunk streaming:** the world spans 10 km, but only chunks near the player are queued. Startup waits for the spawn chunk and its collider; distant chunks and LODs stream in while the player explores. Neverland no longer builds a 2049×2049 height array and all terrain meshes before spawning.
- **Native acceleration:** the C++ GDExtension handles the CPU-heavy chunk build, greedy top-face merging, exposed side faces, LOD skirts and collision-height data. The matching GDScript builder remains a fallback for source-only runs.
- **Debugging:** the in-game **VOXEN DEBUG** button toggles the full VoxEn chunk/LOD/collision/build/queue profiler on Windows and Android. **F3** toggles diagnostic LOD colours; **R** regenerates the landscape with a new seed.
- **Preserved systems:** original main menu, loading screen, procedural sky, time/weather selectors, flight mode, keyboard and touch controls, grass, flowers and UI assets.

## Run

1. Open the project in **Godot 4.7.2** and let the editor import resources.
2. Press **F5**, then start a new game from the existing menu.
3. The loading screen remains until the starting chunk and collision are ready. The rest of the world continues loading during gameplay.
4. Windows: WASD/arrows to move and mouse to look. Android: the left-side touch joystick to move and a second finger on the right side to look. Double-tap the right half (or double-tap Space on desktop) to toggle flight.
5. Press **VOXEN DEBUG** in the top-left to show/hide the VoxEn profiler. Press F3 for LOD diagnostic colours and R to regenerate.

## Native library build

This repository contains all GDExtension source files but **does not include compiled .dll or .so libraries**. Build locally for the platform you target. If the extension is missing, the GDScript mesher fallback will be selected, though native builds are recommended for performance.

Requirements: a C++ compiler, Python 3.12+, SCons, the Godot 4.7.2 C++ bindings (godot-cpp 10.0.0-stable), and the Android NDK for Android builds.

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

Windows x86-64 (run in a shell with the native compiler configured):

~~~sh
scons platform=windows target=template_debug arch=x86_64
scons platform=windows target=template_release arch=x86_64
~~~

Android ARM64 (with Android NDK environment configured):

~~~sh
scons platform=android target=template_debug arch=arm64
scons platform=android target=template_release arch=arm64
~~~

The extension descriptor is at **bin/voxen_native.gdextension**. Compiled outputs are expected under **bin/linux/**, **bin/windows/** and **bin/android/**. Do not commit generated libraries.

## Architecture and optimisation choices

- **Native C++:** per-chunk CPU mesh building, height-cache sampling, greedy top-face meshing, exposed side faces, LOD skirts and collision-height arrays. These operations run frequently and perform substantial numeric work.
- **GDScript:** world scheduling, queue/deadline priority, WorkerThreadPool task lifecycle, applying Godot mesh/physics resources on the main thread, player movement, UI, weather/time, vegetation and generation orchestration. This preserves engine lifecycle safety and keeps gameplay logic easy to modify.
- **Startup:** only the spawn area and collision gate the first spawn. Distant terrain is not preloaded in full; streaming prioritises chunks in the player's direction and updates detail by LOD.
- **Terrain compatibility:** the original height equations and seeded range construction are retained and shared with the native mesher through a compact mountain profile. The native path and script fallback use the same surface generator.
- **Current limitation:** this is a height-column voxel landscape, not a full 3D voxel volume. It does not yet support enclosed caves, overhangs, destructible voxel edits or persistence. These require volumetric density/occupancy data, a 3D mesher and suitable collision generation.

## Smoke test

With Godot 4.7.2 installed:

~~~sh
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/neverland_voxen_smoke_test.gd
~~~

## Version history

### 0.1.0
- First Neverland build integrated with VoxEn 0.3.5.
- Preserves the existing menu, sky, controls, flight and vegetation.
- Converts the terrain profile to voxel columns with 10 cm logical voxels and streamed chunk meshing.
- Adds native source, profiler toggle and startup gating on the spawn collider.
