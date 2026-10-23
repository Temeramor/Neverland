shader_type spatial;
render_mode diffuse_burley, cull_back, ambient_light_disabled;

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

float voronoi_edge(vec2 p) {
    vec2 base_cell = floor(p);
    vec2 local = fract(p);
    float nearest = 10.0;
    float second_nearest = 10.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 offset_cell = vec2(float(x), float(y));
            vec2 cell = base_cell + offset_cell;
            vec2 random_point = vec2(
                hash21(cell + vec2(3.1, 8.7)),
                hash21(cell + vec2(19.4, 2.6))
            ) * 0.72 + 0.14;
            vec2 delta = offset_cell + random_point - local;
            float distance_squared = dot(delta, delta);
            if (distance_squared < nearest) {
                second_nearest = nearest;
                nearest = distance_squared;
            } else if (distance_squared < second_nearest) {
                second_nearest = distance_squared;
            }
        }
    }
    return sqrt(second_nearest) - sqrt(nearest);
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
    // The pixel choice is still stochastic, but each sample maps through smooth gradients
    // rather than hard palette cutoffs. Macro strata are blended separately below.
    // Darken only the base stone palette; fixed crack, pit and chip colors are applied later.
    float p = clamp(pick, 0.0, 1.0);
    vec3 c0 = palette_color(vec3(0.205, 0.215, 0.220));
    vec3 c1 = palette_color(vec3(0.315, 0.325, 0.330));
    vec3 c2 = palette_color(vec3(0.395, 0.400, 0.400));
    // Keep distinct stone hues, but compress the pale end of the palette into darker mid-grays.
    vec3 c3 = palette_color(vec3(0.425, 0.430, 0.425));
    vec3 c4 = palette_color(vec3(0.465, 0.460, 0.445));
    vec3 c5 = palette_color(vec3(0.510, 0.500, 0.480));
    vec3 c6 = palette_color(vec3(0.555, 0.545, 0.515));
    vec3 c7 = palette_color(vec3(0.610, 0.590, 0.550));
    vec3 color;
    if (p < 0.16) {
        color = mix(c0, c1, smoothstep(0.0, 0.16, p));
    } else if (p < 0.32) {
        color = mix(c1, c2, smoothstep(0.16, 0.32, p));
    } else if (p < 0.49) {
        color = mix(c2, c3, smoothstep(0.32, 0.49, p));
    } else if (p < 0.66) {
        color = mix(c3, c4, smoothstep(0.49, 0.66, p));
    } else if (p < 0.82) {
        color = mix(c4, c5, smoothstep(0.66, 0.82, p));
    } else if (p < 0.94) {
        color = mix(c5, c6, smoothstep(0.82, 0.94, p));
    } else {
        color = mix(c6, c7, smoothstep(0.94, 1.0, p));
    }
    return color * 0.86;
}

vec3 rock_pixel(vec2 pixel_cell, vec2 pixel_world) {
    // Base rock remains the original Neverland pixel palette. No mineral bands,
    // vertical fissure overlays, chips, pitting or broad warm/cool tint layers.
    float broad_tone = value_noise(pixel_world * 0.021 + vec2(13.8, seed_low * 0.0006));
    float random_cell = hash21(pixel_cell + vec2(0.0, 21.8));
    float pick = clamp(random_cell + (broad_tone - 0.5) * 0.12, 0.001, 0.999);
    vec3 base_color = rock_palette(pick);

    // Gently warp the cellular field, so crack paths are irregular rather than straight
    // or aligned into bands. Both fields are continuous world-space functions.
    vec2 warp = (vec2(
        value_noise(pixel_world * 0.024 + vec2(3.3, 8.1)),
        value_noise(pixel_world * 0.021 + vec2(19.7, 2.4))
    ) - 0.5) * 2.6;
    vec2 crack_world = pixel_world + warp;

    float micro_edge = voronoi_edge(crack_world / 5.5 + vec2(seed_low * 0.0008, 6.7));
    float broad_edge = voronoi_edge(crack_world / 13.0 + vec2(19.4, seed_high * 0.0007));

    // Width is locally varied by smooth noise. The crack's visibility also fades with
    // continuous noise, letting segments emerge and taper away without hard cut-off ends.
    float micro_width_noise = value_noise(crack_world * 0.11 + vec2(7.4, seed_low * 0.0003));
    float broad_width_noise = value_noise(crack_world * 0.047 + vec2(15.2, seed_high * 0.0005));
    float micro_width = mix(0.018, 0.060, micro_width_noise);
    float broad_width = mix(0.020, 0.075, broad_width_noise);

    float micro_lifetime = smoothstep(0.24, 0.72,
        value_noise(crack_world * 0.095 + vec2(29.1, seed_low * 0.0004)));
    float broad_lifetime = smoothstep(0.30, 0.76,
        value_noise(crack_world * 0.042 + vec2(3.7, seed_high * 0.0006)));
    float micro_crack = (1.0 - smoothstep(micro_width, micro_width + 0.035, micro_edge))
        * micro_lifetime;
    float broad_crack = (1.0 - smoothstep(broad_width, broad_width + 0.030, broad_edge))
        * broad_lifetime;

    // Use a muted dark stone colour and preserve some base pixels through each crack.
    // The overlapping scales yield varied cracks without heavy bands across a mountain.
    float crack_strength = clamp(micro_crack * 0.50 + broad_crack * 0.62, 0.0, 0.78);
    return mix(base_color, palette_color(vec3(0.105, 0.112, 0.112)), crack_strength);
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
    // 0.1 m texel cells align with the voxel grid and remain world-locked across chunks.
    // Quantise a point slightly inside the voxel, so top and side faces share one colour cell.
    vec3 voxel_cell_3d = floor((world_position - normal * 0.001) / max(pixel_size, 0.1));
    vec3 voxel_center_world = (voxel_cell_3d + vec3(0.5)) * max(pixel_size, 0.1);
    // The packed 2D cell is only a deterministic hash key; spatial noise uses real X/Z metres.
    vec2 pixel_cell = vec2(voxel_cell_3d.x + voxel_cell_3d.y * 37.0,
                           voxel_cell_3d.z + voxel_cell_3d.y * 17.0);
    vec2 pixel_center = voxel_center_world.xz;
    float broad_tone = value_noise(pixel_center * 0.035 + vec2(seed_low * 0.0002, 8.3));
    float pick = clamp(hash21(pixel_cell + vec2(0.0, 7.7)) + (broad_tone - 0.5) * 0.24, 0.001, 0.999);

    // Keep the underlying colour cell fixed at 10 cm. When it becomes sub-pixel,
    // blend towards broad palette variation to prevent shimmering without enlarging texels.
    // Distance-based blending is identical on every face of a given voxel.
    float detail_distance = distance(CAMERA_POSITION_WORLD, voxel_center_world);
    float grass_detail_weight = 1.0 - smoothstep(100.0, 360.0, detail_distance);
    float rock_detail_weight = 1.0 - smoothstep(220.0, 520.0, detail_distance);

    if (debug_lod_colors) {
        float variation = mix(0.92, 1.08, pick);
        ALBEDO = clamp(COLOR.rgb * variation, vec3(0.0), vec3(1.0));
    } else if (COLOR.g > COLOR.r * 1.35) {
        vec3 broad_grass = grass_palette(clamp(0.18 + broad_tone * 0.66, 0.001, 0.999));
        if (detail_distance < 140.0) {
            ALBEDO = grass_pixel(pixel_cell, pixel_center);
        } else if (detail_distance < 360.0) {
            vec3 detailed_grass = grass_pixel(pixel_cell, pixel_center);
            ALBEDO = mix(broad_grass, detailed_grass, grass_detail_weight);
        } else {
            ALBEDO = broad_grass;
        }
    } else if (COLOR.r > COLOR.g * 1.15) {
        vec3 broad_soil = soil_palette(clamp(0.18 + broad_tone * 0.64, 0.001, 0.999));
        if (detail_distance < 160.0) {
            vec3 color = soil_palette(pick);
            color *= mix(0.90, 1.08, broad_tone);
            ALBEDO = color;
        } else if (detail_distance < 420.0) {
            vec3 color = soil_palette(pick);
            color *= mix(0.90, 1.08, broad_tone);
            ALBEDO = mix(broad_soil, color, 1.0 - smoothstep(160.0, 420.0, detail_distance));
        } else {
            ALBEDO = broad_soil;
        }
    } else {
        // At long range, skip Voronoi-crack evaluation entirely. A continuous macro
        // palette keeps the mountains readable while avoiding sub-pixel crack shimmer.
        vec3 distant_rock = rock_palette(clamp(0.18 + broad_tone * 0.66, 0.001, 0.999));
        if (detail_distance < 220.0) {
            ALBEDO = rock_pixel(pixel_cell, pixel_center);
        } else if (detail_distance < 520.0) {
            ALBEDO = mix(distant_rock, rock_pixel(pixel_cell, pixel_center), rock_detail_weight);
        } else {
            ALBEDO = distant_rock;
        }
    }
    // Small constant fill keeps the palette readable in shadow while avoiding
    // ambient-normal darkening on the upper/lower halves of the voxel terrain.
    EMISSION = ALBEDO * 0.12;
    ROUGHNESS = 0.96;
}

void light() {
    // Uniform direct illumination across face orientations, but still use ATTENUATION
    // so shadows cast by the coarse terrain silhouette remain visible on the voxels.
    DIFFUSE_LIGHT += ALBEDO * LIGHT_COLOR * ATTENUATION / PI;
}
