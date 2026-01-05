#version 450

layout(location = 4) in vec4 in_uv; // xy = min, zw = max
layout(location = 5) in vec4 in_pos; // xy = min, zw = max
layout(location = 6) in vec4 in_color;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;

layout(set = 1, binding = 0) uniform PushConstants {
    vec2 u_Resolution;
    float u_Time;
};

void main() {
    out_color = in_color;

    vec2 corner = vec2(gl_VertexIndex >> 1, gl_VertexIndex & 1);

    vec2 uv = mix(in_uv.xy, in_uv.zw, corner);
    out_uv = uv;

    vec2 pos_px = mix(in_pos.xy, in_pos.zw, corner);
    vec2 pos_norm = pos_px / u_Resolution;
    vec2 pos_ndc = pos_norm * 2.0 - 1.0;

    gl_Position = vec4(pos_ndc.x, -pos_ndc.y, 0., 1.);
}
