#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_envmap_texture;
layout(std430, set = 2, binding = 1) readonly buffer WaterData {
    vec4 sky_color;
    vec4 deep_color;
};

#include <lib/water_common.glsl>
#include <lib/transform.glsl>

void main() {
    vec3 view_dir = normalize(in_position);
    vec3 normal = -in_normal; // Vertex shader normal is up, underwater is down
    vec3 refract_dir = refract(view_dir, normal, 1.333);
    vec3 reflect_dir = reflect(view_dir, normal);

    vec3 color;

    if (length(refract_dir) > 0.0) {
        color = texture(u_envmap_texture, equirectangularUV(refract_dir)).rgb;
        color *= BRIGHTNESS;
    } else {
        color = getWaterColor(reflect_dir);
    }

    float fog = 1.0 - exp(-length(in_position) * 0.05);
    color = mix(color, getWaterColor(view_dir), fog);
    out_color = vec4(color, 1.);
}
