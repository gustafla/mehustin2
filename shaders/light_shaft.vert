#version 450

layout(location = 0) in vec3 in_pos;

layout(location = 8) in vec4 in_inst_pos_scale;
layout(location = 9) in vec4 in_inst_rot_quat;

layout(location = 0) out vec3 out_local_pos;
layout(location = 1) out vec3 out_pos;
layout(location = 2) flat out vec3 out_cam_pos;
layout(location = 3) flat out float out_anim_offset;

layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_cam_pos;
    vec4 u_cam_right;
    vec4 u_cam_up;
    float u_time;
};

#include <lib/transform.glsl>

void main() {
    vec3 cam_pos = u_cam_pos.xyz;

    vec3 rotated_pos = rotateVector(in_pos, in_inst_rot_quat);
    vec3 scaled_pos = rotated_pos * in_inst_pos_scale.w;
    vec3 translated_pos = scaled_pos + in_inst_pos_scale.xyz;

    out_local_pos = in_pos;
    out_pos = translated_pos - cam_pos;
    out_cam_pos = cam_pos;
    out_anim_offset = in_inst_pos_scale.y;

    vec4 clip_pos = u_view_projection * vec4(translated_pos, 1.);
    gl_Position = clip_pos;
}
