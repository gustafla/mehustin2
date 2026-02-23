#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_local_pos;
layout(location = 2) flat in vec3 in_color;
layout(location = 3) flat in vec3 in_cam_pos;

layout(location = 0) out vec4 out_color;

layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_time_g;
    float u_time;
    float u_time_r;
};

#define SUN_COLOR vec3(0)
#define SKY_COLOR vec3(0)
#include <lib/water_common.glsl>

void main() {
    float v = 1.0 - in_local_pos.y * 2.0;
    vec3 color = pow(v * cos(v * 3.14 * 3) * 0.333 + 1.0, 6.0) * in_color;
    out_color = vec4(color * exp(-k_sigma_t * length(in_pos)), 1.0);
}
