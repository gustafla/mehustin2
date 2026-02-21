#version 450

layout(location = 0) in vec3 in_pos;
layout(location = 1) in vec3 in_normal;
layout(location = 2) flat in vec3 in_cam_pos;

layout(location = 0) out vec3 out_color;

struct PointLight {
    vec3 position;
    vec3 color;
};

layout(std430, set = 2, binding = 0) readonly buffer PointLightData {
    vec3 ambient;
    uint n_lights;
    PointLight lights[];
};

#define SUN_COLOR vec3(0)
#define SKY_COLOR vec3(0)
#include <lib/water_common.glsl>

void main() {
    float dist = length(in_pos);
    vec3 view_dir = normalize(in_pos);
    vec3 color = ambient;

    for (int i = 0; i < min(MAX_LIGHTS, n_lights); i++) {
        PointLight light = lights[i];
        vec3 cam_rel_pos = light.position - in_cam_pos;
        vec3 ptol = cam_rel_pos - in_pos;
        vec3 dir = normalize(ptol);
        float cos_theta = max(dot(in_normal, dir), 0.0);
        float d = length(ptol);
        float a = 1.0 / (d * d);
        color += light.color * cos_theta * a;
    }

    out_color = color * exp(-k_sigma_t * dist);
}
