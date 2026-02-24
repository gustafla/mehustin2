#version 450

layout(location = 0) in vec3 in_pos;

layout(location = 0) out vec3 out_pos;
layout(location = 1) out vec2 out_uv;
layout(location = 2) out vec3 out_cam_pos;

const float base_dia = 1000.0;

layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_cam_pos;
    vec4 u_cam_right;
    vec4 u_cam_up;
    float u_time;
};

void main() {
    // Generates: (0, 0), (0, 1), (1, 0), (1, 1)
    vec2 corner = vec2(gl_VertexIndex >> 1, gl_VertexIndex & 1);
    out_uv = vec2(corner.x, 1.0 - corner.y);
    vec2 offset = vec2(corner.x - 0.5, 0.5 - corner.y);

    vec3 vertex_pos = in_pos
            + (u_cam_right.xyz * offset.x * base_dia)
            + (u_cam_up.xyz * offset.y * base_dia);
    out_pos = vertex_pos;
    out_cam_pos = u_cam_pos.xyz;

    gl_Position = u_view_projection * vec4(vertex_pos, 1.0);
}
