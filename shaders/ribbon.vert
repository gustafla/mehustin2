#version 450

layout(location = 0) in vec3 in_position;
layout(location = 4) in vec2 in_uv;

layout(location = 8) in vec4 in_inst_pos_scale;
layout(location = 9) in vec4 in_inst_rot_quat;

layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_cam_pos;
    vec4 u_cam_right;
    vec4 u_cam_up;
    float u_time;
};

layout(location = 0) out vec3 out_position;
layout(location = 1) sample out vec2 out_uv;
layout(location = 2) out float out_fade;
layout(location = 3) flat out vec3 out_cam_pos;
layout(location = 4) flat out vec2 out_phase_dir;

#include <lib/transform.glsl>

void main() {
    vec3 cam_pos = u_cam_pos.xyz;
    float fade = 1.0 - (abs(0.5 - in_uv.y) * 2);
    float phase = 334. + in_inst_pos_scale.y * 0.42 * 3.14;
    float dir = 1.0;
    if (sin(phase * 12581) < 0.0) {
        dir = -1.0;
    }

    vec3 rotated_pos = rotateVector(in_position, in_inst_rot_quat);
    vec3 scaled_pos = rotated_pos * in_inst_pos_scale.w;

    // Animate
    vec3 translation = in_inst_pos_scale.xyz;
    float t = u_time + phase;
    translation.z -= sin(t * dir * 0.014 + in_uv.y * 14.5 + in_uv.y * 27.6) * 30.124;
    translation.x += cos(t * dir * 0.033 + in_uv.y * 14.5 + in_uv.y * 17.6) * 30.124;
    translation.y += sin(t * -dir * 0.05 + in_uv.y * 4.5 + in_uv.y * 13.6) * 16.124 + 10.;

    translation.z += sin(t * dir * 0.14 + in_uv.y * 14.5 + in_uv.y * 27.6) * 3.124;
    translation.x += cos(t * dir * 0.33 + in_uv.y * 14.5 + in_uv.y * 17.6) * 3.124;
    translation.y += sin(t * -dir * 0.5 + in_uv.y * 4.5 + in_uv.y * 13.6) * 6.124 + 3.;

    vec3 translated_pos = scaled_pos + translation;

    out_position = translated_pos - cam_pos; // Camera relative
    out_uv = in_uv;
    out_fade = fade;
    out_cam_pos = cam_pos;
    out_phase_dir = vec2(phase, dir);
    vec4 clip_pos = u_view_projection * vec4(translated_pos, 1.);
    gl_Position = clip_pos;
}
