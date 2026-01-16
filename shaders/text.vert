#version 450

layout(location = 6) in vec4 in_instance_uv; // xy = min, zw = max
layout(location = 7) in vec4 in_instance_position; // xy = min, zw = max
layout(location = 8) in vec4 in_instance_color;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;

void main() {
    out_color = in_instance_color;

    // Generates: (0, 0), (0, 1), (1, 0), (1, 1)
    vec2 corner = vec2(gl_VertexIndex >> 1, gl_VertexIndex & 1);
    out_uv = mix(in_instance_uv.xy, in_instance_uv.zw, corner);

    vec2 pos_px = mix(in_instance_position.xy, in_instance_position.zw, corner);
    vec2 pos_norm = pos_px / vec2(WIDTH, HEIGHT);
    vec2 pos_ndc = pos_norm * vec2(2, -2) + vec2(-1, 1);

    gl_Position = vec4(pos_ndc, 0.0, 1.0);
}
