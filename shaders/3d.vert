#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

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
layout(location = 1) out vec3 out_normal;
layout(location = 2) flat out vec3 out_cam_pos;

#include <lib/transform.glsl>

void main() {
    vec3 cam_pos = u_cam_pos.xyz;

    vec3 rotated_pos = rotateVector(in_position, in_inst_rot_quat);
    vec3 scaled_pos = rotated_pos * in_inst_pos_scale.w;
    vec3 translated_pos = scaled_pos + in_inst_pos_scale.xyz;

    out_position = translated_pos - cam_pos; // Camera relative
    out_normal = rotateVector(in_normal, in_inst_rot_quat);
    out_cam_pos = cam_pos;
    vec4 clip_pos = u_view_projection * vec4(translated_pos, 1.);
    gl_Position = clip_pos;
}
