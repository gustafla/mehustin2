#version 450

layout(location = 0) out vec2 out_pos;
layout(location = 1) out vec2 out_uv;

void main() {
    vec2 c = vec2(1, 1);
    vec2 corner = vec2(gl_VertexIndex & 1, gl_VertexIndex >> 1);
    vec2 pos = mix(-c, c, corner);
    out_pos = pos;
    out_uv = pos * vec2(0.5, -0.5) + 0.5;
    gl_Position = vec4(pos, c);
}
