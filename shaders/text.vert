#version 450

layout(location = 4) in vec4 in_uv; // xy = min, zw = max
layout(location = 5) in vec4 in_pos; // xy = min, zw = max
layout(location = 6) in vec4 in_color;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;

void main() {
    out_color = in_color;

    // Generates: (0, 0), (0, 1), (1, 0), (1, 1)
    vec2 corner = vec2(gl_VertexIndex >> 1, gl_VertexIndex & 1);
    out_uv = mix(in_uv.xy, in_uv.zw, corner);

    vec2 pos_px = mix(in_pos.xy, in_pos.zw, corner);
    vec2 pos_norm = pos_px / vec2(WIDTH, HEIGHT);
    vec2 pos_ndc = pos_norm * vec2(2, -2) + vec2(-1, 1);

    gl_Position = vec4(pos_ndc, 0.0, 1.0);
}
