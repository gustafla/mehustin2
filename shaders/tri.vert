#version 450

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec3 out_view_ray;
layout(location = 2) flat out vec3 out_cam_pos;

layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_cam_pos;
    vec4 u_cam_right;
    vec4 u_cam_up;
    float u_time;
};

void main() {
    // Generates: (0, 0), (2, 0), (0, 2)
    vec2 pos = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    out_uv = vec2(pos.x, 1.0 - pos.y);

    // Clip coordinates at the far plane
    vec2 ndc_pos = pos * 2.0 - 1.0; // (-1, -1), (3, -1), (-1, 3)
    vec4 clip_pos = vec4(ndc_pos, 1.0, 1.0);

    // Unproject view frustum rays to world space
    mat4 inv_vp = inverse(u_view_projection);
    vec4 world_pos_h = inv_vp * clip_pos;
    vec3 world_pos = world_pos_h.xyz / world_pos_h.w;
    out_view_ray = world_pos - u_cam_pos.xyz;
    out_cam_pos = u_cam_pos.xyz;

    gl_Position = clip_pos;
}
