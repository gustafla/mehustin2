#version 450

layout(location = 6) in vec4 in_instance_uv; // xy = min, zw = max
layout(location = 7) in vec4 in_instance_position; // xy = min, zw = max
layout(location = 8) in vec4 in_instance_color;
layout(location = 9) in uvec2 in_instance_style; // NEW: x: font, y: effect

layout(location = 0) out vec2 out_uv;
layout(location = 1) flat out vec4 out_color;
layout(location = 2) flat out uvec2 out_style;

void main() {
    out_color = in_instance_color;
    out_style = in_instance_style;

    // Generates: (0, 0), (0, 1), (1, 0), (1, 1)
    vec2 corner = vec2(gl_VertexIndex >> 1, gl_VertexIndex & 1);
    out_uv = mix(in_instance_uv.xy, in_instance_uv.zw, corner);

    vec2 ndc = mix(in_instance_position.xy, in_instance_position.zw, corner);

    gl_Position = vec4(ndc, 0.0, 1.0);
}
