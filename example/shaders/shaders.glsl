#version 450

#ifdef VERTEX
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

void main() {
    vec3 cam_position = u_cam_pos.xyz;
    out_position = in_position - cam_position;
    out_normal = in_normal;
    vec4 clip_position = u_view_projection * vec4(in_position, 1.);
    gl_Position = clip_position;
}
#endif // VERTEX

#ifdef FRAGMENT
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

layout(location = 0) out vec4 out_color;

void main() {
    vec3 dir = normalize(-in_position);
    float lighting = max(dot(dir, in_normal), 0.0);
    vec3 color = abs(in_position) * 0.5;
    out_color = vec4(lighting * color, 1.0);
}
#endif // FRAGMENT
