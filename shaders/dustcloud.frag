#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec3 in_cam_pos;

layout(location = 0) out vec4 out_color;

#define SUN_COLOR vec3(0)
#define SKY_COLOR vec3(0)
#include <lib/water_common.glsl>
#include <lib/noise.glsl>
#include <lib/color.glsl>

struct PointLight {
    vec3 position;
    vec3 color;
};

layout(std430, set = 2, binding = 0) readonly buffer PointLightData {
    vec3 ambient;
    uint n_lights;
    PointLight lights[];
};

layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_time_g;
    float u_time;
    float u_time_r;
};

void main() {
    float dist = length(in_pos - in_cam_pos);
    float alpha = 1.0 - length(in_uv * 2.0 - 1.0);
    alpha *= noise((in_pos + u_time_g) * 0.03);
    alpha *= smoothstep(-980, -950, in_pos.y);
    alpha *= smoothstep(10.0, 40.0, dist);

    vec3 color = ambient;
    color.r *= color.r;
    color *= exp(-k_sigma_t * dist);
    if (brightness(color * alpha) < 0.001) {
        discard;
    }

    out_color = vec4(color, alpha);
}
