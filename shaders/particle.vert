#version 450

layout(location = 0) sample out vec2 out_uv;
layout(location = 1) flat out float out_alpha;

const float cube_size = 512.0;
const float cube_size_rcp = 1.0 / cube_size;
const float base_dia = 0.32;
const float pixels = 3.0;

layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_cam_pos;
    vec4 u_cam_right;
    vec4 u_cam_up;
    float u_time;
};

vec3 worldPos() {
    float t = u_time * 0.5;

    float idx = float(gl_InstanceIndex);
    vec3 seed = vec3(
            fract(sin(idx * 0.371) * 43758.54),
            fract(cos(idx * 0.114) * 43758.54),
            fract(sin(idx * 0.324) * 43758.54)
        );

    vec3 drift_velocity = vec3(0.01, -0.005, -0.005);
    vec3 moving_pos = seed + (drift_velocity * t);

    vec3 cam = u_cam_pos.xyz * cube_size_rcp;
    vec3 p = moving_pos - cam;
    p = fract(p) - 0.5;
    vec3 world_pos = (p + cam) * cube_size;

    vec3 turbulence = vec3(
            sin(world_pos.z * 0.05 + t) * 2.0,
            cos(world_pos.y * 0.04 + t * 0.8) * 2.0,
            sin(world_pos.x * 0.03 + t * 0.5) * 4.0
        );

    return world_pos + turbulence;
}

void main() {
    // Generates: (0, 0), (0, 1), (1, 0), (1, 1)
    vec2 corner = vec2(gl_VertexIndex >> 1, gl_VertexIndex & 1);
    out_uv = vec2(corner.x, 1.0 - corner.y);
    vec2 offset = vec2(corner.x - 0.5, 0.5 - corner.y);

    vec3 center_pos = worldPos();
    vec4 center_clip = u_view_projection * vec4(center_pos, 1.0);
    float projected_dia = (base_dia * HEIGHT) / center_clip.w;

    float alpha = projected_dia / pixels;
    alpha *= alpha;
    alpha = min(alpha, 1.0 / alpha);
    out_alpha = alpha;

    float clamped_dia = max(projected_dia, pixels);
    float scale_factor = clamped_dia / projected_dia;

    vec3 vertex_pos = center_pos
            + (u_cam_right.xyz * offset.x * base_dia * scale_factor)
            + (u_cam_up.xyz * offset.y * base_dia * scale_factor);

    gl_Position = u_view_projection * vec4(vertex_pos, 1.0);
}
