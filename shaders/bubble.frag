#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec3 in_cam_pos;

layout(location = 0) out vec4 out_color;

layout(std430, set = 2, binding = 0) readonly buffer WaterData {
    vec4 sky_color;
    vec3 sun_dir;
    float brightness;
};

layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_time_g;
    float u_time;
    float u_time_r;
};

#include <lib/water_common.glsl>

void main() {
    vec3 view_dir = normalize(in_pos);

    vec2 uv = in_uv;
    float len = 1.0 - length(uv * 2.0 - 1.0);
    float alpha = smoothstep(0.1, 0.2, len);

    vec3 color = underwaterFog(vec3(0.0), 1e6, in_cam_pos, view_dir, sun_dir);

    out_color = vec4(color, max(alpha, 0.0));
}
