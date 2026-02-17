#version 450

layout(location = 0) in vec3 in_local_pos;
layout(location = 1) in vec3 in_pos;
layout(location = 2) flat in vec3 in_cam_pos;
layout(location = 3) flat in float in_anim_offset;

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
    float t = u_time_g + in_anim_offset;
    float angle = atan(in_local_pos.z, in_local_pos.x) * 1.5;
    float fade = in_local_pos.y * clamp(-0.5 - (in_cam_pos.y + in_pos.y) * 0.2, 0.0, 1.0);
    float noise = sin(angle * 10.0 + t * 2.0);
    noise += sin(angle * 12.0 - t * 2.3);
    noise += sin(angle * 4.0 + t * 2.5);
    noise += sin(angle * 5.0 - t * 1.4);
    noise = noise * 0.5 + 0.5;
    noise = pow(noise, 4.0);
    float alpha = noise * fade * 0.1;
    if (alpha < 0.01) {
        discard;
    }

    vec3 color = underwaterFog(vec3(0.0), 1e9, in_cam_pos, normalize(in_pos), sun_dir);
    out_color = vec4(color, clamp(alpha, 0.0, 1.0));
}
