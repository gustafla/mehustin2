#version 450

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec3 out_pos;
layout(location = 2) flat out vec3 out_cam_pos;

layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_cam_pos;
    vec4 u_cam_right;
    vec4 u_cam_up;
    float u_time;
};

vec3 worldPos() {
    float x = fract(sin(float(gl_InstanceIndex) * 0.371));
    float y = fract(cos(float(gl_InstanceIndex) * 0.114));
    float z = fract(sin(float(gl_InstanceIndex) * 0.324));
    return (vec3(x, y, z) - 0.5) * 20.;
}

void main() {
    out_cam_pos = u_cam_pos.xyz;

    // Generates: (0, 0), (0, 1), (1, 0), (1, 1)
    vec2 corner = vec2(gl_VertexIndex >> 1, gl_VertexIndex & 1);
    out_uv = vec2(corner.x, 1.0 - corner.y);
    vec2 offset = vec2(corner.x - 0.5, 0.5 - corner.y);

    vec3 center_pos = worldPos();
    float size = 0.5;
    vec3 vertex_pos = center_pos
            + (u_cam_right.xyz * offset.x * size)
            + (u_cam_up.xyz * offset.y * size);

    out_pos = vertex_pos - u_cam_pos.xyz;
    gl_Position = u_view_projection * vec4(vertex_pos, 1.0);
}
