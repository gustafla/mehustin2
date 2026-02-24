#version 450

layout(location = 0) in vec3 in_position;
layout(location = 4) in vec2 in_uv;

layout(location = 8) in vec4 in_inst_pos_scale;
layout(location = 9) in vec4 in_inst_rot_quat;
layout(location = 10) in vec4 in_inst_color;

layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_cam_pos;
    vec4 u_cam_right;
    vec4 u_cam_up;
    float u_time;
};

layout(location = 0) out vec3 out_position;
layout(location = 1) out vec2 out_uv;
layout(location = 2) flat out vec3 out_color;
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
    float t = u_time + sine(u_time + 1, freq) * 0.3;
    position.xz *= sine(t, freq) * 0.6 + 0.75;
    position.y -= sine(t, freq) * 0.1;

    vec3 rotated_pos = rotateVector(position, in_inst_rot_quat);
    vec3 scaled_pos = rotated_pos * in_inst_pos_scale.w;
    vec3 translated_pos = scaled_pos + in_inst_pos_scale.xyz;

    // Animate
    float v = max(-position.y, 0.0);
    translated_pos.y += sin((translated_pos.z * 1.5 + translated_pos.x * 0.5) * freq * 0.412 * 2.0 * 3.14159265 + u_time * 0.01) * 1.2 * v;
    translated_pos.x += cos((translated_pos.x + translated_pos.z * 0.5) * freq * 0.459 * 2.0 * 3.14159265 - u_time * 0.03) * 0.8 * v;
    translated_pos.z += sin((translated_pos.y + translated_pos.x * 0.5) * freq * 0.657 * 2.0 * 3.14159265 + u_time * 0.01) * 0.8 * v;

    out_position = translated_pos - cam_pos; // Camera relative
    out_uv = in_uv;
    out_color = in_inst_color.rgb;
    out_cam_pos = cam_pos;
    vec4 clip_pos = u_view_projection * vec4(translated_pos, 1.);
    gl_Position = clip_pos;
}
