#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec3 in_view_ray;

layout(location = 0) out vec4 out_color;

layout(std430, set = 2, binding = 0) buffer WaterData {
    vec4 sky_color;
    vec4 deep_color;
};

const float brightness = 5;

vec3 getWaterColor(vec3 dir) {
    return mix(deep_color.rgb, sky_color.rgb, pow(max(dir.y, 0.0), 0.5)) * brightness;
}

void main() {
    vec3 view_dir = normalize(in_view_ray);
    out_color = vec4(getWaterColor(view_dir), 1.);
}
