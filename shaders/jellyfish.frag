#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_local_pos;
layout(location = 3) flat in vec3 in_cam_pos;

layout(location = 0) out vec4 out_color;

layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_time_g;
    float u_time;
    float u_time_r;
};

layout(std430, set = 2, binding = 0) readonly buffer WaterData {
    vec4 sky_color;
    vec3 sun_dir;
    float brightness;
};

#include <lib/water_common.glsl>

void main() {
    // vec3 color = underwaterFog(vec3(1.0), 1e9, in_cam_pos, normalize(in_pos), sun_dir);
    // out_color = vec4(color, 1.0);
    out_color = vec4(in_normal, 1.0);
}
