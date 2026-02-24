#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec2 in_uv;
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

float tex(vec2 uv, float fade) {
    // Center tentacle
    float a = smoothstep(0.0, 1.0, uv.x) * smoothstep(-1.0, 0.0, -uv.x) * 3. * fade;

    // Outer
    a += max(1.0 - uv.x * 10, 0);
    a += max(uv.x * 10 - 9.0, 0);

    return a;
}

void main() {
    float fade = (1.0 - in_uv.y);
    fade *= tex(in_uv, fade);

    if (fade < 0.01) {
        discard;
    }

    fade = min(fade, 1.0);
    out_color = vec4(in_color * exp(-k_sigma_t * length(in_pos)), 1.0) * fade;
}
