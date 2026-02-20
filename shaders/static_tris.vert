#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

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

void main() {
    vec3 cam_pos = u_cam_pos.xyz;

    out_position = in_position - cam_pos; // Camera relative
    out_normal = in_normal;
    out_cam_pos = cam_pos;
    vec4 clip_pos = u_view_projection * vec4(in_position, 1.);
    gl_Position = clip_pos;
}
