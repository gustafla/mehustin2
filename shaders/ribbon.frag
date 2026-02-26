#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) sample in vec2 in_uv;
layout(location = 2) in float in_fade;
layout(location = 3) flat in vec3 in_cam_pos;
layout(location = 4) flat in vec2 in_phase_dir;

layout(location = 0) out vec4 out_color;

layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_time_g;
    float u_time;
    float u_time_r;
};

#define SUN_COLOR vec3(0)
#define SKY_COLOR vec3(0)
#include <lib/water_common.glsl>
#include <lib/color.glsl>

float tex(vec2 uv) {
    float n = 3;
    float f = 100;
    float t = (u_time_g / n) * 0.2 * in_phase_dir.y + in_phase_dir.x;
    float a = fract((uv.y - t / n) * n - 0.5 / n) - 0.5;
    float sinc = max(1 - a * a * f, 0.0);
    sinc *= 6;
    sinc *= sinc;

    float z0 = uv.x - 0.5;
    z0 += sin(uv.y * 430.) * 0.35;
    float snake = smoothstep(0.0, 0.1, z0);
    snake -= smoothstep(-0.1, -0.2, -z0);

    float z1 = uv.x - 0.5;
    z1 += sin(uv.y * 321.) * 0.3;
    snake += smoothstep(0.0, 0.1, z1);
    snake -= smoothstep(-0.1, -0.2, -z1);

    float b = sinc * snake;
    return b;
}

void main() {
    float fade = in_fade;
    float pattern = tex(in_uv);

    if (fade * pattern < 0.01) {
        discard;
    }

    vec3 color = vec3(1.0, 0.2, 0.8) * pattern;
    out_color = vec4(color * exp(-k_sigma_t * length(in_pos)), fade);
}
