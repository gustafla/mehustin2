#version 450

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec2 out_ndc;

void main() {
    // Generates: (-1, -1), (3, -1), (-1, 3)
    vec2 pos = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
    out_uv = vec2(pos.x, 1.0 - pos.y);

    vec2 ndc_pos = pos * 2.0 - 1.0;
    out_ndc = ndc_pos;

    gl_Position = vec4(ndc_pos, 1.0, 1.0);
}
