const float BRIGHTNESS = 5.0;
const vec3 SUN_DIR = normalize(vec3(0.5, 0.2, 0.5));

vec3 getWaterColor(vec3 view_dir) {
    vec3 base = mix(deep_color.rgb, sky_color.rgb, pow(max(view_dir.y, 0.0), 0.5));

    float sun_alignment = max(dot(view_dir, SUN_DIR), 0.0);

    vec3 water = deep_color.rgb;
    vec3 haze0 = water * sun_alignment;
    vec3 haze1 = water * pow(sun_alignment, 2.0) * 2.0;
    vec3 haze2 = water * pow(sun_alignment, 16.0) * 10.0;

    return (base + haze0 + haze1 + haze2) * BRIGHTNESS;
}
