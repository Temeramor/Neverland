#include "voxen_native_builder.h"

#include <godot_cpp/classes/fast_noise_lite.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector2i.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

using namespace godot;

namespace {

constexpr double VOXEL_SIZE = 0.1;
constexpr int32_t BASE_MESH_STEP_VOXELS = 2;
constexpr int HEIGHT_CACHE_STEP_VOXELS = 5;
constexpr int LOD_SKIRT_DEPTH_VOXELS = 80;
constexpr double SKIRT_ALPHA_LEFT = 0.80;
constexpr double SKIRT_ALPHA_RIGHT = 0.84;
constexpr double SKIRT_ALPHA_NORTH = 0.88;
constexpr double SKIRT_ALPHA_SOUTH = 0.92;

constexpr int AIR = 0;
constexpr int GRASS = 1;
constexpr int SOIL = 2;
constexpr int ROCK = 3;

struct NoiseSet {
    int64_t seed_value = 0;
    double world_size_m = 10000.0;
    Ref<FastNoiseLite> macro;
    Ref<FastNoiseLite> hills;
    Ref<FastNoiseLite> detail;
    Ref<FastNoiseLite> ridges;
    Ref<FastNoiseLite> micro_ridge;
    Ref<FastNoiseLite> transition;

    struct MountainSegment {
        double ax = 0.0, az = 0.0, dx = 0.0, dz = 0.0;
        double length_squared = 1.0, width = 1.0, height = 1.0, phase = 0.0;
    };
    std::vector<MountainSegment> mountain_segments;

    static Ref<FastNoiseLite> make_noise(int32_t seed, int octaves, double gain,
            FastNoiseLite::FractalType fractal_mode = FastNoiseLite::FRACTAL_FBM) {
        Ref<FastNoiseLite> noise;
        noise.instantiate();
        noise->set_seed(seed);
        noise->set_noise_type(FastNoiseLite::TYPE_SIMPLEX);
        noise->set_frequency(1.0);
        noise->set_fractal_type(fractal_mode);
        noise->set_fractal_octaves(octaves);
        noise->set_fractal_lacunarity(2.05);
        noise->set_fractal_gain(gain);
        return noise;
    }

    explicit NoiseSet(int64_t seed) : seed_value(seed) {
        // Per-job noise resources avoid sharing mutable Godot objects across workers.
        macro = make_noise(static_cast<int32_t>(seed + 101), 4, 0.52);
        hills = make_noise(static_cast<int32_t>(seed + 307), 4, 0.52);
        detail = make_noise(static_cast<int32_t>(seed + 503), 3, 0.52);
        ridges = make_noise(static_cast<int32_t>(seed + 709), 5, 0.52, FastNoiseLite::FRACTAL_RIDGED);
        micro_ridge = make_noise(static_cast<int32_t>(seed + 907), 3, 0.52, FastNoiseLite::FRACTAL_RIDGED);
        transition = make_noise(static_cast<int32_t>(seed + 1301), 2, 0.52);
    }

    void configure_from_job(const Dictionary &job_data, double fallback_world_size_m) {
        world_size_m = static_cast<double>(job_data.get("terrain_world_size_m", fallback_world_size_m));
        mountain_segments.clear();
        const Array profile = job_data.get("mountain_profile", Array());
        for (int64_t i = 0; i < profile.size(); ++i) {
            const Dictionary item = profile[i];
            const Vector2 start = item.get("start", Vector2());
            const Vector2 delta = item.get("delta", Vector2());
            MountainSegment segment;
            segment.ax = start.x;
            segment.az = start.y;
            segment.dx = delta.x;
            segment.dz = delta.y;
            segment.length_squared = std::max(0.001, static_cast<double>(item.get("length_squared", 1.0)));
            segment.width = static_cast<double>(item.get("width", 1.0));
            segment.height = static_cast<double>(item.get("height", 1.0));
            segment.phase = static_cast<double>(item.get("phase", 0.0));
            mountain_segments.push_back(segment);
        }
    }

    static double smoothstep(double edge_a, double edge_b, double value) {
        const double t = std::clamp((value - edge_a) / (edge_b - edge_a), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    double surface_height(double x, double z) const {
        const double macro_value = macro->get_noise_2d(x * 0.00028, z * 0.00028);
        const double hills_value = hills->get_noise_2d(x * 0.00115, z * 0.00115);
        const double detail_value = detail->get_noise_2d(x * 0.0048, z * 0.0048);
        const double ridge_detail = (ridges->get_noise_2d(x * 0.00082, z * 0.00082) + 1.0) * 0.5;
        const double micro_value = micro_ridge->get_noise_2d(x * 0.0034, z * 0.0034);

        double height = 26.0 + macro_value * 17.0 + hills_value * 10.0;
        height += std::max(hills_value - 0.12, 0.0) * 18.0;
        height += detail_value * 3.8;

        double mountain_height = 0.0;
        for (const MountainSegment &segment : mountain_segments) {
            const double along = std::clamp(
                ((x - segment.ax) * segment.dx + (z - segment.az) * segment.dz) /
                    segment.length_squared, 0.0, 1.0);
            const double closest_x = segment.ax + segment.dx * along;
            const double closest_z = segment.az + segment.dz * along;
            const double offset_x = x - closest_x;
            const double offset_z = z - closest_z;
            const double distance_squared = offset_x * offset_x + offset_z * offset_z;
            const double broad_radius = segment.width * 1.72;
            if (distance_squared >= broad_radius * broad_radius) continue;
            const double distance = std::sqrt(distance_squared);
            const double broad_mask = std::clamp(1.0 - distance / broad_radius, 0.0, 1.0);
            const double cliff_mask = std::clamp(1.0 - distance / segment.width, 0.0, 1.0);
            const double crest_profile = 0.77 + 0.23 * std::abs(std::sin(along * 3.14159265358979323846 * 2.1 + segment.phase));
            const double rough_profile = 0.79 + 0.21 * ridge_detail;
            const double foothills = std::pow(broad_mask, 1.28) * (segment.height * 0.39 + 75.0);
            const double crest = std::pow(cliff_mask, 0.94) * segment.height * crest_profile * rough_profile;
            mountain_height = std::max(mountain_height, std::max(foothills, crest));
        }

        height += mountain_height;
        if (mountain_height > 1.0) {
            const double mountain_mask = std::clamp(mountain_height / 900.0, 0.0, 1.0);
            height += mountain_mask * (micro_value * 34.0 + detail_value * 22.0);
        }
        const double point_length = std::sqrt(x * x + z * z);
        const double spawn_fade = 1.0 - smoothstep(420.0, 1420.0, point_length);
        const double spawn_height = 25.0 + macro_value * 3.0 + detail_value * 0.8;
        height = height * (1.0 - spawn_fade) + spawn_height * spawn_fade;
        return std::max(VOXEL_SIZE, std::clamp(height, -80.0, 1600.0));
    }

    int32_t surface_height_voxels(double x, double z) const {
        return std::max<int32_t>(1, static_cast<int32_t>(std::llround(surface_height(x, z) / VOXEL_SIZE)));
    }

    int32_t surface_material(double height_m, double slope, double x, double z) const {
        const double transition_noise = transition->get_noise_2d(x * 0.008, z * 0.008) * 0.05;
        return slope + transition_noise >= 0.39 ? ROCK : GRASS;
    }
};

Color rgb8(int r, int g, int b, double a = 1.0) {
    return Color(static_cast<double>(r) / 255.0,
                 static_cast<double>(g) / 255.0,
                 static_cast<double>(b) / 255.0,
                 a);
}

struct MeshBuild {
    NoiseSet noise;
    Vector2i coord;
    int lod = 0;
    bool debug_lod_colors = false;
    bool want_collision = false;
    bool build_collision = false;

    double world_min_x = 0.0;
    double world_min_z = 0.0;
    int32_t world_size_voxels = 0;
    int32_t start_voxel_x = 0;
    int32_t start_voxel_z = 0;
    int32_t size_voxels_x = 0;
    int32_t size_voxels_z = 0;
    int32_t step_voxels = 1;
    int32_t cache_step_voxels = HEIGHT_CACHE_STEP_VOXELS;
    int32_t cells_x = 0;
    int32_t cells_z = 0;
    int32_t halo = 0;
    int32_t grid_width = 0;
    int32_t grid_depth = 0;
    double cell_size = VOXEL_SIZE;

    Dictionary neighbor_lods;
    std::vector<int32_t> height_cache;
    int32_t cache_width = 0;
    int32_t cache_depth = 0;
    int32_t cache_origin_x = 0;
    int32_t cache_origin_z = 0;
    std::vector<int32_t> raw_heights;
    std::vector<int32_t> heights;
    std::vector<uint8_t> surface_types;

    std::vector<Vector3> vertices;
    std::vector<Vector3> normals;
    std::vector<Color> colors;
    std::vector<int32_t> indices;

    explicit MeshBuild(int64_t seed) : noise(seed) {}

    static double cubic_interpolate(double p0, double p1, double p2, double p3, double t) {
        return p1 + 0.5 * t * (p2 - p0 + t * (2.0 * p0 - 5.0 * p1 +
            4.0 * p2 - p3 + t * (3.0 * (p1 - p2) + p3 - p0)));
    }

    static int32_t floor_to_int(double value) {
        return static_cast<int32_t>(std::floor(value));
    }

    int32_t sample_height_voxels(double gx, double gz) const {
        if (gx < 0.0 || gz < 0.0 ||
            gx >= static_cast<double>(world_size_voxels) ||
            gz >= static_cast<double>(world_size_voxels)) {
            return 0;
        }
        const double world_x = world_min_x + gx * VOXEL_SIZE;
        const double world_z = world_min_z + gz * VOXEL_SIZE;
        return noise.surface_height_voxels(world_x, world_z);
    }

    int32_t cached_height_voxels(double gx, double gz) const {
        if (gx < 0.0 || gz < 0.0 ||
            gx >= static_cast<double>(world_size_voxels) ||
            gz >= static_cast<double>(world_size_voxels)) {
            return 0;
        }
        const double fx = (gx - static_cast<double>(cache_origin_x)) /
            static_cast<double>(cache_step_voxels);
        const double fz = (gz - static_cast<double>(cache_origin_z)) /
            static_cast<double>(cache_step_voxels);
        const int32_t bx = floor_to_int(fx);
        const int32_t bz = floor_to_int(fz);
        const double tx = std::clamp(fx - static_cast<double>(bx), 0.0, 1.0);
        const double tz = std::clamp(fz - static_cast<double>(bz), 0.0, 1.0);

        double rows[4] = {0.0, 0.0, 0.0, 0.0};
        double h_min = std::numeric_limits<double>::infinity();
        double h_max = -std::numeric_limits<double>::infinity();

        for (int dz = 0; dz < 4; ++dz) {
            const int32_t iz = std::clamp(bz + dz - 1, 0, cache_depth - 1);
            const int32_t x0 = std::clamp(bx - 1, 0, cache_width - 1);
            const int32_t x1 = std::clamp(bx, 0, cache_width - 1);
            const int32_t x2 = std::clamp(bx + 1, 0, cache_width - 1);
            const int32_t x3 = std::clamp(bx + 2, 0, cache_width - 1);
            const double p0 = static_cast<double>(height_cache[static_cast<size_t>(iz) * cache_width + x0]);
            const double p1 = static_cast<double>(height_cache[static_cast<size_t>(iz) * cache_width + x1]);
            const double p2 = static_cast<double>(height_cache[static_cast<size_t>(iz) * cache_width + x2]);
            const double p3 = static_cast<double>(height_cache[static_cast<size_t>(iz) * cache_width + x3]);
            rows[dz] = cubic_interpolate(p0, p1, p2, p3, tx);
            h_min = std::min(h_min, std::min(std::min(p0, p1), std::min(p2, p3)));
            h_max = std::max(h_max, std::max(std::max(p0, p1), std::max(p2, p3)));
        }

        const double height = cubic_interpolate(rows[0], rows[1], rows[2], rows[3], tz);
        return std::max<int32_t>(1, static_cast<int32_t>(std::llround(std::clamp(height, h_min, h_max))));
    }

    int32_t grid_index(int32_t x, int32_t z) const {
        return (z + halo) * grid_width + x + halo;
    }

    int32_t neighbor_lod(const String &direction) const {
        return static_cast<int32_t>(neighbor_lods.get(direction, -1));
    }

    Color material_color(int32_t material_type) const {
        if (debug_lod_colors) {
            switch (lod) {
                case 0: return rgb8(237, 71, 71);
                case 1: return rgb8(232, 161, 47);
                case 2: return rgb8(53, 201, 178);
                case 3: return rgb8(84, 126, 232);
                case 4: return rgb8(177, 107, 224);
                case 5: return rgb8(235, 86, 180);
                default: return rgb8(90, 190, 235);
            }
        }
        switch (material_type) {
            case GRASS: return rgb8(54, 164, 42);
            case SOIL: return rgb8(128, 96, 68);
            case ROCK: return rgb8(119, 121, 115);
            default: return Color(1.0, 1.0, 1.0, 1.0);
        }
    }

    void add_quad(const Vector3 &p0, const Vector3 &p1, const Vector3 &p2,
                  const Vector3 &p3, const Vector3 &normal, const Color &color) {
        const int32_t base_index = static_cast<int32_t>(vertices.size());
        vertices.push_back(p0);
        vertices.push_back(p1);
        vertices.push_back(p2);
        vertices.push_back(p3);
        for (int i = 0; i < 4; ++i) {
            normals.push_back(normal);
            colors.push_back(color);
        }
        // Match the existing GDScript winding convention for Godot's front faces.
        indices.push_back(base_index);
        indices.push_back(base_index + 2);
        indices.push_back(base_index + 1);
        indices.push_back(base_index);
        indices.push_back(base_index + 3);
        indices.push_back(base_index + 2);
    }

    void emit_side_segment(const Vector3 &point_a, const Vector3 &point_b,
                           const Vector3 &normal, int32_t low_y, int32_t high_y,
                           int32_t material_type, bool vertical_first, double edge_alpha = 1.0) {
        if (high_y <= low_y) {
            return;
        }
        const double low_m = static_cast<double>(low_y) * VOXEL_SIZE;
        const double high_m = static_cast<double>(high_y) * VOXEL_SIZE;
        const Vector3 a_low(point_a.x, low_m, point_a.z);
        const Vector3 a_high(point_a.x, high_m, point_a.z);
        const Vector3 b_low(point_b.x, low_m, point_b.z);
        const Vector3 b_high(point_b.x, high_m, point_b.z);
        Color side_color = material_color(material_type);
        if (edge_alpha < 0.95) {
            side_color.a = edge_alpha;
        }
        if (vertical_first) {
            add_quad(a_low, a_high, b_high, b_low, normal, side_color);
        } else {
            add_quad(a_low, b_low, b_high, a_high, normal, side_color);
        }
    }

    void add_segmented_side_face(const Vector3 &p0, const Vector3 &p1,
            const Vector3 &p2, const Vector3 &p3, const Vector3 &normal,
            int32_t low_height_voxels, int32_t high_height_voxels,
            int32_t top_material, bool vertical_first, double edge_alpha = 1.0) {
        (void)p2;
        if (high_height_voxels <= low_height_voxels) {
            return;
        }
        const Vector3 point_a(p0.x, 0.0, p0.z);
        const Vector3 point_b = vertical_first
            ? Vector3(p3.x, 0.0, p3.z)
            : Vector3(p1.x, 0.0, p1.z);
        const int32_t top_start = std::max(low_height_voxels, high_height_voxels - 1);
        const int32_t soil_start = std::max(low_height_voxels, high_height_voxels - 5);
        emit_side_segment(point_a, point_b, normal, low_height_voxels, soil_start, ROCK, vertical_first, edge_alpha);
        emit_side_segment(point_a, point_b, normal, soil_start, top_start, SOIL, vertical_first, edge_alpha);
        emit_side_segment(point_a, point_b, normal, top_start, high_height_voxels, top_material, vertical_first, edge_alpha);
    }

    void build_cache_and_heights() {
        const int32_t macro_offset = std::max<int32_t>(1, static_cast<int32_t>(std::llround(1.0 / cell_size)));
        halo = macro_offset + 1;
        grid_width = cells_x + halo * 2;
        grid_depth = cells_z + halo * 2;
        const int32_t total_samples = grid_width * grid_depth;

        cache_origin_x = floor_to_int(
            static_cast<double>(start_voxel_x - halo * step_voxels - cache_step_voxels * 2) /
            static_cast<double>(cache_step_voxels)) * cache_step_voxels;
        cache_origin_z = floor_to_int(
            static_cast<double>(start_voxel_z - halo * step_voxels - cache_step_voxels * 2) /
            static_cast<double>(cache_step_voxels)) * cache_step_voxels;
        const int32_t cache_end_x = start_voxel_x + size_voxels_x + halo * step_voxels + cache_step_voxels * 2;
        const int32_t cache_end_z = start_voxel_z + size_voxels_z + halo * step_voxels + cache_step_voxels * 2;
        cache_width = static_cast<int32_t>(std::ceil(
            static_cast<double>(cache_end_x - cache_origin_x) / cache_step_voxels)) + 1;
        cache_depth = static_cast<int32_t>(std::ceil(
            static_cast<double>(cache_end_z - cache_origin_z) / cache_step_voxels)) + 1;
        height_cache.resize(static_cast<size_t>(cache_width) * cache_depth);

        for (int32_t cz = 0; cz < cache_depth; ++cz) {
            const double cache_z = static_cast<double>(cache_origin_z + cz * cache_step_voxels);
            for (int32_t cx = 0; cx < cache_width; ++cx) {
                const double cache_x = static_cast<double>(cache_origin_x + cx * cache_step_voxels);
                height_cache[static_cast<size_t>(cz) * cache_width + cx] = sample_height_voxels(cache_x, cache_z);
            }
        }

        raw_heights.resize(static_cast<size_t>(total_samples));
        for (int32_t gz = 0; gz < grid_depth; ++gz) {
            const double global_cell_z = static_cast<double>(start_voxel_z) +
                static_cast<double>(gz - halo) * step_voxels + static_cast<double>(step_voxels) * 0.5;
            for (int32_t gx = 0; gx < grid_width; ++gx) {
                const double global_cell_x = static_cast<double>(start_voxel_x) +
                    static_cast<double>(gx - halo) * step_voxels + static_cast<double>(step_voxels) * 0.5;
                raw_heights[static_cast<size_t>(gz) * grid_width + gx] =
                    cached_height_voxels(global_cell_x, global_cell_z);
            }
        }
        heights = raw_heights;
    }

    void build_surface_types() {
        const int32_t macro_offset = std::max<int32_t>(1, static_cast<int32_t>(std::llround(1.0 / cell_size)));
        surface_types.resize(static_cast<size_t>(cells_x) * cells_z);

        for (int32_t z = 0; z < cells_z; ++z) {
            for (int32_t x = 0; x < cells_x; ++x) {
                const int32_t gx = x + halo;
                const int32_t gz = z + halo;
                const int32_t center_h = raw_heights[static_cast<size_t>(gz) * grid_width + gx];
                const int32_t left_h = raw_heights[static_cast<size_t>(gz) * grid_width + gx - macro_offset];
                const int32_t right_h = raw_heights[static_cast<size_t>(gz) * grid_width + gx + macro_offset];
                const int32_t north_h = raw_heights[static_cast<size_t>(gz - macro_offset) * grid_width + gx];
                const int32_t south_h = raw_heights[static_cast<size_t>(gz + macro_offset) * grid_width + gx];
                const double dx = static_cast<double>(right_h - left_h) * VOXEL_SIZE /
                    (2.0 * macro_offset * cell_size);
                const double dz = static_cast<double>(south_h - north_h) * VOXEL_SIZE /
                    (2.0 * macro_offset * cell_size);
                const double slope = std::sqrt(dx * dx + dz * dz);
                const double world_x = world_min_x +
                    (static_cast<double>(start_voxel_x + x * step_voxels) + step_voxels * 0.5) * VOXEL_SIZE;
                const double world_z = world_min_z +
                    (static_cast<double>(start_voxel_z + z * step_voxels) + step_voxels * 0.5) * VOXEL_SIZE;
                surface_types[static_cast<size_t>(z) * cells_x + x] =
                    static_cast<uint8_t>(noise.surface_material(
                        static_cast<double>(center_h) * VOXEL_SIZE, slope, world_x, world_z));
            }
        }
    }

    void build_greedy_top_faces() {
        std::vector<uint8_t> visited(static_cast<size_t>(cells_x) * cells_z, 0);

        for (int32_t z = 0; z < cells_z; ++z) {
            for (int32_t x = 0; x < cells_x; ++x) {
                const size_t cell_index = static_cast<size_t>(z) * cells_x + x;
                if (visited[cell_index] != 0) {
                    continue;
                }
                const int32_t height_voxels = heights[grid_index(x, z)];
                const uint8_t material_type = surface_types[cell_index];
                int32_t run_x = 1;
                while (x + run_x < cells_x) {
                    const size_t next_cell = static_cast<size_t>(z) * cells_x + x + run_x;
                    if (visited[next_cell] != 0) {
                        break;
                    }
                    if (heights[grid_index(x + run_x, z)] != height_voxels ||
                        surface_types[next_cell] != material_type) {
                        break;
                    }
                    ++run_x;
                }

                int32_t run_z = 1;
                while (z + run_z < cells_z) {
                    bool can_extend = true;
                    for (int32_t dx = 0; dx < run_x; ++dx) {
                        const size_t test_cell = static_cast<size_t>(z + run_z) * cells_x + x + dx;
                        if (visited[test_cell] != 0 ||
                            heights[grid_index(x + dx, z + run_z)] != height_voxels ||
                            surface_types[test_cell] != material_type) {
                            can_extend = false;
                            break;
                        }
                    }
                    if (!can_extend) {
                        break;
                    }
                    ++run_z;
                }

                for (int32_t dz = 0; dz < run_z; ++dz) {
                    for (int32_t dx = 0; dx < run_x; ++dx) {
                        visited[static_cast<size_t>(z + dz) * cells_x + x + dx] = 1;
                    }
                }

                const double x0 = static_cast<double>(x * step_voxels) * VOXEL_SIZE;
                const double x1 = static_cast<double>((x + run_x) * step_voxels) * VOXEL_SIZE;
                const double z0 = static_cast<double>(z * step_voxels) * VOXEL_SIZE;
                const double z1 = static_cast<double>((z + run_z) * step_voxels) * VOXEL_SIZE;
                const double y = static_cast<double>(height_voxels) * VOXEL_SIZE;
                add_quad(Vector3(x0, y, z0), Vector3(x0, y, z1),
                         Vector3(x1, y, z1), Vector3(x1, y, z0),
                         Vector3(0.0, 1.0, 0.0), material_color(material_type));
            }
        }
    }

    void build_exposed_side_faces() {
        for (int32_t z = 0; z < cells_z; ++z) {
            for (int32_t x = 0; x < cells_x; ++x) {
                const int32_t h = heights[grid_index(x, z)];
                if (h <= 0) {
                    continue;
                }
                const int32_t top_material = surface_types[static_cast<size_t>(z) * cells_x + x];
                const double x0 = static_cast<double>(x * step_voxels) * VOXEL_SIZE;
                const double x1 = static_cast<double>((x + 1) * step_voxels) * VOXEL_SIZE;
                const double z0 = static_cast<double>(z * step_voxels) * VOXEL_SIZE;
                const double z1 = static_cast<double>((z + 1) * step_voxels) * VOXEL_SIZE;

                const int32_t h_left = heights[grid_index(x - 1, z)];
                if (h > h_left) {
                    add_segmented_side_face(
                        Vector3(x0, static_cast<double>(h_left) * VOXEL_SIZE, z1),
                        Vector3(x0, static_cast<double>(h) * VOXEL_SIZE, z1),
                        Vector3(x0, static_cast<double>(h) * VOXEL_SIZE, z0),
                        Vector3(x0, static_cast<double>(h_left) * VOXEL_SIZE, z0),
                        Vector3(-1.0, 0.0, 0.0), h_left, h, top_material, true);
                }

                const int32_t h_right = heights[grid_index(x + 1, z)];
                if (h > h_right) {
                    add_segmented_side_face(
                        Vector3(x1, static_cast<double>(h_right) * VOXEL_SIZE, z0),
                        Vector3(x1, static_cast<double>(h) * VOXEL_SIZE, z0),
                        Vector3(x1, static_cast<double>(h) * VOXEL_SIZE, z1),
                        Vector3(x1, static_cast<double>(h_right) * VOXEL_SIZE, z1),
                        Vector3(1.0, 0.0, 0.0), h_right, h, top_material, true);
                }

                const int32_t h_north = heights[grid_index(x, z - 1)];
                if (h > h_north) {
                    add_segmented_side_face(
                        Vector3(x1, static_cast<double>(h_north) * VOXEL_SIZE, z0),
                        Vector3(x0, static_cast<double>(h_north) * VOXEL_SIZE, z0),
                        Vector3(x0, static_cast<double>(h) * VOXEL_SIZE, z0),
                        Vector3(x1, static_cast<double>(h) * VOXEL_SIZE, z0),
                        Vector3(0.0, 0.0, -1.0), h_north, h, top_material, false);
                }

                const int32_t h_south = heights[grid_index(x, z + 1)];
                if (h > h_south) {
                    add_segmented_side_face(
                        Vector3(x0, static_cast<double>(h_south) * VOXEL_SIZE, z1),
                        Vector3(x1, static_cast<double>(h_south) * VOXEL_SIZE, z1),
                        Vector3(x1, static_cast<double>(h) * VOXEL_SIZE, z1),
                        Vector3(x0, static_cast<double>(h) * VOXEL_SIZE, z1),
                        Vector3(0.0, 0.0, 1.0), h_south, h, top_material, false);
                }
            }
        }
    }

    void build_lod_skirts() {
        const int32_t skirt_depth_voxels = std::max<int32_t>(LOD_SKIRT_DEPTH_VOXELS, step_voxels * 8);
        const double x0 = 0.0;
        const double x1 = static_cast<double>(cells_x * step_voxels) * VOXEL_SIZE;
        const double z0 = 0.0;
        const double z1 = static_cast<double>(cells_z * step_voxels) * VOXEL_SIZE;

        if (neighbor_lod("left") >= 0) {
            for (int32_t z = 0; z < cells_z; ++z) {
                const int32_t h = heights[grid_index(0, z)];
                const int32_t outer_h = heights[grid_index(-1, z)];
                const int32_t top = std::min(h, outer_h);
                const int32_t low = std::max(0, top - skirt_depth_voxels);
                add_segmented_side_face(
                    Vector3(x0, static_cast<double>(low) * VOXEL_SIZE, static_cast<double>(z + 1) * step_voxels * VOXEL_SIZE),
                    Vector3(x0, static_cast<double>(top) * VOXEL_SIZE, static_cast<double>(z + 1) * step_voxels * VOXEL_SIZE),
                    Vector3(x0, static_cast<double>(top) * VOXEL_SIZE, static_cast<double>(z) * step_voxels * VOXEL_SIZE),
                    Vector3(x0, static_cast<double>(low) * VOXEL_SIZE, static_cast<double>(z) * step_voxels * VOXEL_SIZE),
                    Vector3(-1.0, 0.0, 0.0), low, top,
                    surface_types[static_cast<size_t>(z) * cells_x], true, SKIRT_ALPHA_LEFT);
            }
        }
        if (neighbor_lod("right") >= 0) {
            for (int32_t z = 0; z < cells_z; ++z) {
                const int32_t h = heights[grid_index(cells_x - 1, z)];
                const int32_t outer_h = heights[grid_index(cells_x, z)];
                const int32_t top = std::min(h, outer_h);
                const int32_t low = std::max(0, top - skirt_depth_voxels);
                add_segmented_side_face(
                    Vector3(x1, static_cast<double>(low) * VOXEL_SIZE, static_cast<double>(z) * step_voxels * VOXEL_SIZE),
                    Vector3(x1, static_cast<double>(top) * VOXEL_SIZE, static_cast<double>(z) * step_voxels * VOXEL_SIZE),
                    Vector3(x1, static_cast<double>(top) * VOXEL_SIZE, static_cast<double>(z + 1) * step_voxels * VOXEL_SIZE),
                    Vector3(x1, static_cast<double>(low) * VOXEL_SIZE, static_cast<double>(z + 1) * step_voxels * VOXEL_SIZE),
                    Vector3(1.0, 0.0, 0.0), low, top,
                    surface_types[static_cast<size_t>(z) * cells_x + cells_x - 1], true, SKIRT_ALPHA_RIGHT);
            }
        }
        if (neighbor_lod("north") >= 0) {
            for (int32_t x = 0; x < cells_x; ++x) {
                const int32_t h = heights[grid_index(x, 0)];
                const int32_t outer_h = heights[grid_index(x, -1)];
                const int32_t top = std::min(h, outer_h);
                const int32_t low = std::max(0, top - skirt_depth_voxels);
                add_segmented_side_face(
                    Vector3(static_cast<double>(x + 1) * step_voxels * VOXEL_SIZE, static_cast<double>(low) * VOXEL_SIZE, z0),
                    Vector3(static_cast<double>(x) * step_voxels * VOXEL_SIZE, static_cast<double>(low) * VOXEL_SIZE, z0),
                    Vector3(static_cast<double>(x) * step_voxels * VOXEL_SIZE, static_cast<double>(top) * VOXEL_SIZE, z0),
                    Vector3(static_cast<double>(x + 1) * step_voxels * VOXEL_SIZE, static_cast<double>(top) * VOXEL_SIZE, z0),
                    Vector3(0.0, 0.0, -1.0), low, top,
                    surface_types[static_cast<size_t>(x)], false, SKIRT_ALPHA_NORTH);
            }
        }
        if (neighbor_lod("south") >= 0) {
            for (int32_t x = 0; x < cells_x; ++x) {
                const int32_t h = heights[grid_index(x, cells_z - 1)];
                const int32_t outer_h = heights[grid_index(x, cells_z)];
                const int32_t top = std::min(h, outer_h);
                const int32_t low = std::max(0, top - skirt_depth_voxels);
                add_segmented_side_face(
                    Vector3(static_cast<double>(x) * step_voxels * VOXEL_SIZE, static_cast<double>(low) * VOXEL_SIZE, z1),
                    Vector3(static_cast<double>(x + 1) * step_voxels * VOXEL_SIZE, static_cast<double>(low) * VOXEL_SIZE, z1),
                    Vector3(static_cast<double>(x + 1) * step_voxels * VOXEL_SIZE, static_cast<double>(top) * VOXEL_SIZE, z1),
                    Vector3(static_cast<double>(x) * step_voxels * VOXEL_SIZE, static_cast<double>(top) * VOXEL_SIZE, z1),
                    Vector3(0.0, 0.0, 1.0), low, top,
                    surface_types[static_cast<size_t>(cells_z - 1) * cells_x + x], false, SKIRT_ALPHA_SOUTH);
            }
        }
    }

    Dictionary run(const Dictionary &job_data, int64_t build_started_usec) {
        coord = job_data.get("coord", Vector2i());
        const Dictionary request = job_data.get("request", Dictionary());
        lod = static_cast<int32_t>(request.get("lod", 0));
        neighbor_lods = job_data.get("neighbor_lods", Dictionary());
        debug_lod_colors = static_cast<bool>(job_data.get("debug_lod_colors", false));
        world_min_x = static_cast<double>(job_data.get("world_min_x", 0.0));
        world_min_z = static_cast<double>(job_data.get("world_min_z", 0.0));
        world_size_voxels = static_cast<int32_t>(job_data.get("world_size_voxels", 0));
        start_voxel_x = static_cast<int32_t>(request.get("start_x", 0));
        start_voxel_z = static_cast<int32_t>(request.get("start_z", 0));
        size_voxels_x = static_cast<int32_t>(request.get("size_x", 0));
        size_voxels_z = static_cast<int32_t>(request.get("size_z", 0));
        want_collision = static_cast<bool>(request.get("collision", false));
        build_collision = static_cast<bool>(job_data.get("build_collision", want_collision));

        if (lod < 0 || lod > 6 || size_voxels_x <= 0 || size_voxels_z <= 0 || world_size_voxels <= 0) {
            return Dictionary();
        }

        step_voxels = std::max<int32_t>(1, static_cast<int32_t>(request.get("step_voxels", BASE_MESH_STEP_VOXELS << lod)));
        cache_step_voxels = std::max<int32_t>(HEIGHT_CACHE_STEP_VOXELS, step_voxels);
        cell_size = static_cast<double>(step_voxels) * VOXEL_SIZE;
        cells_x = static_cast<int32_t>(std::ceil(static_cast<double>(size_voxels_x) / step_voxels));
        cells_z = static_cast<int32_t>(std::ceil(static_cast<double>(size_voxels_z) / step_voxels));

        noise.configure_from_job(job_data, static_cast<double>(world_size_voxels) * VOXEL_SIZE);
        build_cache_and_heights();
        build_surface_types();

        // Conservative reserve avoids repeated growth in the geometry hot loop.
        const size_t base_cells = static_cast<size_t>(cells_x) * cells_z;
        vertices.reserve(base_cells * 8);
        normals.reserve(base_cells * 8);
        colors.reserve(base_cells * 8);
        indices.reserve(base_cells * 12);

        build_greedy_top_faces();
        build_exposed_side_faces();
        build_lod_skirts();

        PackedVector3Array packed_vertices;
        PackedVector3Array packed_normals;
        PackedColorArray packed_colors;
        PackedInt32Array packed_indices;
        packed_vertices.resize(static_cast<int64_t>(vertices.size()));
        packed_normals.resize(static_cast<int64_t>(normals.size()));
        packed_colors.resize(static_cast<int64_t>(colors.size()));
        packed_indices.resize(static_cast<int64_t>(indices.size()));
        for (size_t i = 0; i < vertices.size(); ++i) {
            packed_vertices.set(static_cast<int64_t>(i), vertices[i]);
            packed_normals.set(static_cast<int64_t>(i), normals[i]);
            packed_colors.set(static_cast<int64_t>(i), colors[i]);
        }
        for (size_t i = 0; i < indices.size(); ++i) {
            packed_indices.set(static_cast<int64_t>(i), indices[i]);
        }

        Dictionary out;
        out["coord"] = coord;
        out["lod"] = lod;
        out["step_voxels"] = step_voxels;
        out["neighbor_lods_used"] = neighbor_lods.duplicate(true);
        out["debug_lod_colors"] = debug_lod_colors;
        out["vertices"] = packed_vertices;
        out["normals"] = packed_normals;
        out["colors"] = packed_colors;
        out["indices"] = packed_indices;
        out["position"] = Vector3(
            world_min_x + static_cast<double>(start_voxel_x) * VOXEL_SIZE,
            0.0,
            world_min_z + static_cast<double>(start_voxel_z) * VOXEL_SIZE);
        out["has_geometry"] = !indices.empty();
        out["want_collision"] = want_collision;
        out["worker_started_usec"] = build_started_usec;

        if (want_collision && build_collision) {
            constexpr int32_t collision_step_voxels = 2;
            const int32_t collision_width = size_voxels_x / collision_step_voxels + 1;
            const int32_t collision_depth = size_voxels_z / collision_step_voxels + 1;
            PackedFloat32Array collision_heights;
            collision_heights.resize(static_cast<int64_t>(collision_width) * collision_depth);
            for (int32_t cz = 0; cz < collision_depth; ++cz) {
                const double global_z = static_cast<double>(start_voxel_z + cz * collision_step_voxels);
                for (int32_t cx = 0; cx < collision_width; ++cx) {
                    const double global_x = static_cast<double>(start_voxel_x + cx * collision_step_voxels);
                    const int32_t height_voxels = cached_height_voxels(global_x, global_z);
                    collision_heights.set(
                        static_cast<int64_t>(cz) * collision_width + cx,
                        static_cast<float>(height_voxels) * 0.5f);
                }
            }
            Dictionary collision_data;
            collision_data["width"] = collision_width;
            collision_data["depth"] = collision_depth;
            collision_data["heights"] = collision_heights;
            collision_data["step_m"] = static_cast<double>(collision_step_voxels) * VOXEL_SIZE;
            out["collision_height_map"] = collision_data;
        }

        out["build_usec"] = Time::get_singleton()->get_ticks_usec() - build_started_usec;
        return out;
    }
};

} // namespace

void VoxEnNativeBuilder::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("build_mesh_data", "job_data"),
        &VoxEnNativeBuilder::build_mesh_data);
    ClassDB::bind_method(D_METHOD("set_result", "value"), &VoxEnNativeBuilder::set_result);
    ClassDB::bind_method(D_METHOD("get_result"), &VoxEnNativeBuilder::get_result);
    ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "result"), "set_result", "get_result");
}

Dictionary VoxEnNativeBuilder::build_mesh_data(const Dictionary &job_data) {
    const int64_t started_usec = Time::get_singleton()->get_ticks_usec();
    const int64_t seed = static_cast<int64_t>(job_data.get("seed", 240518));
    MeshBuild build(seed);
    result = build.run(job_data, started_usec);
    return result;
}

void VoxEnNativeBuilder::set_result(const Dictionary &value) {
    result = value;
}

Dictionary VoxEnNativeBuilder::get_result() const {
    return result;
}
