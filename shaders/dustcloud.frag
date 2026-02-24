#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec3 in_cam_pos;

layout(location = 0) out vec4 out_color;

#define SUN_COLOR vec3(0)
#define SKY_COLOR vec3(0)
#include <lib/water_common.glsl>
#include <lib/noise.glsl>

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
    alpha *= noise(in_pos * 0.1);
    alpha *= smoothstep(-1000, -950, in_pos.y);
    alpha *= smoothstep(10.0, 40.0, dist);

    if (alpha < 0.001) {
        discard;
    }

    vec3 color = vec3(0.0);
    for (int i = 0; i < MAX_LIGHTS; i++) {
        if (i >= n_lights) {
            break;
        }

        PointLight light = lights[i];
        vec3 ptol = light.position - in_pos;
        float d = length(ptol);
        float a = 1.0 / (d * d);
        color += light.color * a;
    }

    out_color = vec4(color * exp(-k_sigma_t * dist), alpha);
}
