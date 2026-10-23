shader_type spatial;
render_mode diffuse_burley, cull_back;

uniform float pixel_size : hint_range(0.1, 1.2, 0.05) = 0.1;
uniform float seed_low = 240518.0;
uniform float seed_high = 0.0;
uniform bool debug_lod_colors = false;
uniform vec4 skirt_visibility = vec4(1.0);

varying vec3 world_position;
varying vec3 world_normal;

vec3 palette_color(vec3 srgb) {
    return pow(srgb, vec3(2.2));
}

float hash21(vec2 p) {
    vec2 seed_shift = vec2(
        fract(seed_low * 0.000017 + seed_high * 0.000071),
        fract(seed_low * 0.000053 + seed_high * 0.000029)
    );
    p += seed_shift;
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + vec3(33.33));
    return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Keep the original Neverland grass palette (sRGB swatches converted to linear light).
vec3 grass_palette(float pick) {
    if (pick < 0.055) return palette_color(vec3(0.180, 0.270, 0.120));
    if (pick < 0.145) return palette_color(vec3(0.220, 0.340, 0.110));
    if (pick < 0.285) return palette_color(vec3(0.250, 0.400, 0.120));
    if (pick < 0.435) return palette_color(vec3(0.285, 0.435, 0.135));
    if (pick < 0.600) return palette_color(vec3(0.315, 0.465, 0.150));
    if (pick < 0.735) return palette_color(vec3(0.340, 0.430, 0.170));
    if (pick < 0.855) return palette_color(vec3(0.270, 0.380, 0.120));
    if (pick < 0.960) return palette_color(vec3(0.365, 0.465, 0.195));
    return palette_color(vec3(0.500, 0.580, 0.280));
}

vec3 grass_pixel(vec2 pixel_cell, vec2 pixel_world) {
    float broad_tone = value_noise(pixel_world * 0.027 + vec2(seed_low * 0.0003, 4.2));
    float random_cell = hash21(pixel_cell + vec2(0.0, 7.7));
    float pick = clamp(random_cell + (broad_tone - 0.5) * 0.22, 0.001, 0.999);
    vec3 color = grass_palette(pick);

    float fleck = hash21(pixel_cell + vec2(81.2, 18.4));
    if (fleck > 0.987) {
        color = mix(color, palette_color(vec3(0.741, 0.741, 0.467)), 0.68);
    } else if (fleck < 0.018) {
        color = mix(color, palette_color(vec3(0.275, 0.290, 0.173)), 0.62);
    }
    return color;
}

vec3 soil_palette(float pick) {
    if (pick < 0.18) return palette_color(vec3(0.31, 0.20, 0.11));
    if (pick < 0.42) return palette_color(vec3(0.39, 0.26, 0.14));
    if (pick < 0.70) return palette_color(vec3(0.46, 0.31, 0.17));
    if (pick < 0.90) return palette_color(vec3(0.51, 0.36, 0.20));
    return palette_color(vec3(0.56, 0.40, 0.23));
}

vec3 rock_palette(float pick) {
    if (pick < 0.12) return palette_color(vec3(0.23, 0.25, 0.26));
    if (pick < 0.32) return palette_color(vec3(0.30, 0.32, 0.32));
    if (pick < 0.55) return palette_color(vec3(0.36, 0.37, 0.36));
    if (pick < 0.78) return palette_color(vec3(0.42, 0.42, 0.39));
    if (pick < 0.94) return palette_color(vec3(0.47, 0.46, 0.42));
    return palette_color(vec3(0.53, 0.50, 0.44));
}

void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
    // Skirt faces use special vertex alpha tags; hide them only when the neighbour is ready at the same LOD.
    if (COLOR.a < 0.95) {
        float edge_code = floor((COLOR.a - 0.80) * 25.0 + 0.5);
        float edge_visible = skirt_visibility.x;
        if (edge_code > 0.5 && edge_code < 1.5) {
            edge_visible = skirt_visibility.y;
        } else if (edge_code > 1.5 && edge_code < 2.5) {
            edge_visible = skirt_visibility.z;
        } else if (edge_code > 2.5) {
            edge_visible = skirt_visibility.w;
        }
        if (edge_visible < 0.5) {
            discard;
        }
    }
    vec3 normal = normalize(world_normal);
    vec2 projected;
    if (abs(normal.y) >= abs(normal.x) && abs(normal.y) >= abs(normal.z)) {
        projected = world_position.xz;
    } else if (abs(normal.x) >= abs(normal.z)) {
        projected = world_position.zy;
    } else {
        projected = world_position.xy;
    }

    // 0.1 m texel cells align with the voxel grid and remain world-locked across chunks.
    // Quantise a point slightly inside the voxel, so top and side faces share one colour cell.
    vec3 voxel_cell_3d = floor((world_position - normal * 0.001) / max(pixel_size, 0.1));
    vec2 pixel_cell = vec2(voxel_cell_3d.x + voxel_cell_3d.y * 37.0,
                           voxel_cell_3d.z + voxel_cell_3d.y * 17.0);
    vec2 pixel_center = (pixel_cell + vec2(0.5)) * pixel_size;
    float broad_tone = value_noise(pixel_center * 0.035 + vec2(seed_low * 0.0002, 8.3));
    float pick = clamp(hash21(pixel_cell + vec2(0.0, 7.7)) + (broad_tone - 0.5) * 0.24, 0.001, 0.999);
    float fleck = hash21(pixel_cell + vec2(81.2, 18.4));

    // Keep the underlying colour cell fixed at 10 cm. When it becomes sub-pixel,
    // blend towards broad palette variation to prevent shimmering without enlarging texels.
    float pixel_footprint = max(length(dFdx(projected)), length(dFdy(projected)));
    float grass_detail_weight = 1.0 - smoothstep(
        max(pixel_size, 0.1) * 0.85,
        max(pixel_size, 0.1) * 2.2,
        pixel_footprint
    );

    if (debug_lod_colors) {
        float variation = mix(0.92, 1.08, pick);
        ALBEDO = clamp(COLOR.rgb * variation, vec3(0.0), vec3(1.0));
    } else if (COLOR.g > COLOR.r * 1.35) {
        vec3 detailed_grass = grass_pixel(pixel_cell, pixel_center);
        vec3 broad_grass = grass_palette(clamp(0.18 + broad_tone * 0.66, 0.001, 0.999));
        ALBEDO = mix(broad_grass, detailed_grass, grass_detail_weight);
    } else if (COLOR.r > COLOR.g * 1.15) {
        vec3 color = soil_palette(pick);
        color *= mix(0.90, 1.08, broad_tone);
        ALBEDO = color;
    } else {
        vec3 color = rock_palette(pick);
        float strata = value_noise(pixel_center * vec2(0.025, 0.050) + vec2(seed_high * 0.0001, 3.1));
        color *= mix(0.90, 1.06, strata);
        if (fleck > 0.991) {
            color = mix(color, palette_color(vec3(0.65, 0.62, 0.55)), 0.22);
        }
        ALBEDO = color;
    }
    ROUGHNESS = 0.96;
}
