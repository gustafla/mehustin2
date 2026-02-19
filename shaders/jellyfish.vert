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
layout(location = 2) out vec3 out_local_position;
layout(location = 3) flat out vec3 out_cam_pos;

#include <lib/transform.glsl>

float sine(float t, float f) {
    return sin(t * 3.14159265 * 2.0 * f) * 0.5 + 0.5;
}

void main() {
    vec3 cam_pos = u_cam_pos.xyz;

    float freq = 1.0 / in_inst_pos_scale.w;

    vec3 position = in_position;

    // Main swimming pulse
    float v = 1.0 - position.y * 2.0;
    float t = u_time + sine(u_time + 1, freq) * 0.3;
    position.xz *= sine(t, freq) * 0.6 * v + 0.5;
    position.y -= sine(t, freq) * 0.1;

    // Shape
    float u = atan(position.x, position.z);
    position.xz *= sine(u + t, 1.333) * 0.1 * pow(v, 3.0) + 0.95;
    position.xz *= sine(u + 0.5 + u_time * 0.3, 1) * 0.3 * pow(v, 4.0) + 0.85;

    vec3 rotated_pos = rotateVector(position, in_inst_rot_quat);
    vec3 scaled_pos = rotated_pos * in_inst_pos_scale.w;
    vec3 translated_pos = scaled_pos + in_inst_pos_scale.xyz;

    out_position = translated_pos - cam_pos; // Camera relative
    out_normal = rotateVector(in_normal, in_inst_rot_quat);
    out_local_position = in_position;
    out_cam_pos = cam_pos;
    vec4 clip_pos = u_view_projection * vec4(translated_pos, 1.);
    gl_Position = clip_pos;
}
