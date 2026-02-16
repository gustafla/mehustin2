#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) flat in vec3 in_cam_pos;

layout(location = 0) out vec4 out_color;

layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_global_time;
};

layout(set = 2, binding = 0) uniform sampler2D u_envmap_texture;
layout(set = 2, binding = 1) uniform sampler2D u_noise_texture;
layout(std430, set = 2, binding = 2) readonly buffer WaterData {
    vec4 sky_color;
    vec3 sun_dir;
    float brightness;
};

#include <lib/transform.glsl>
#include <lib/water_common.glsl>

vec3 ripple(vec3 normal, vec2 uv) {
    float t = u_global_time;

    float n1 = texture(u_noise_texture, (uv * 0.1) + vec2(t * 0.02, t * 0.01)).r;
    float n2 = texture(u_noise_texture, (uv * 0.25) - vec2(t * 0.05, t * 0.03)).r;

    float noise = (n1 + n2) * 0.5;

    vec3 n = normal;
    float strength = 0.15;
    n.x += (noise - 0.5) * strength;
    n.z += (noise - 0.5) * strength;

    return normalize(n);
}

void main() {
    float dist = length(in_position);
    vec3 view_dir = normalize(in_position);
    vec3 normal = ripple(-in_normal, in_position.xz * 0.05);

    float ior_spread = 0.01;
    vec3 refract_r = refract(view_dir, normal, water_ior - ior_spread);
    vec3 refract_g = refract(view_dir, normal, water_ior);
    vec3 refract_b = refract(view_dir, normal, water_ior + ior_spread);

    vec3 reflect_dir = reflect(view_dir, normal);
    vec3 color = vec3(0.0);

    if (length(refract_g) > 0.0) {
        vec3 env_color = vec3(
                texture(u_envmap_texture, sphereUV(refract_r)).r,
                texture(u_envmap_texture, sphereUV(refract_g)).g,
                texture(u_envmap_texture, sphereUV(refract_b)).b
            );
        color = env_color * brightness;
    } else {
        // When reflecting down, the light seen in the reflection is scatter from below
        color = underwaterFog(color, 1e6, in_position, reflect_dir, sun_dir);
    }

    color = underwaterFog(color, dist, in_cam_pos, view_dir, sun_dir);
    out_color = vec4(clamp(color, 0, 10), 1.);
}
