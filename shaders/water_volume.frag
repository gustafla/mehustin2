#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec3 in_view_ray;
layout(location = 2) flat in vec3 in_cam_pos;

layout(location = 0) out vec4 out_color;

layout(std430, set = 2, binding = 0) readonly buffer WaterData {
    vec4 sky_color;
    vec3 sun_dir;
    float brightness;
};

#include <lib/water_common.glsl>

void main() {
    vec3 view_dir = normalize(in_view_ray);
    vec3 color = underwaterFog(vec3(0.0), 1e6, in_cam_pos, view_dir, sun_dir);
    out_color = vec4(color, 1.);
}
