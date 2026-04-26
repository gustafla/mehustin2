#version 450

#ifdef VERTEX
layout(location = 8) in vec4 in_instance_uv; // xy = min, zw = max
layout(location = 9) in vec4 in_instance_position; // xy = min, zw = max
layout(location = 10) in vec4 in_instance_color;
layout(location = 11) in uvec2 in_instance_style;

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
#endif // VERTEX

#ifdef FRAGMENT
layout(location = 0) in vec2 in_uv;
layout(location = 1) flat in vec4 in_color;
layout(location = 2) flat in uvec2 in_style;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2DArray u_font_atlas;

layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_time_g;
    float u_time;
    float u_time_r;
};

void main() {
    vec3 coord = vec3(in_uv, float(in_style.x));

    vec4 msdf = texture(u_font_atlas, coord);
    float dist = max(min(msdf.r, msdf.g), min(max(msdf.r, msdf.g), msdf.b));

    float smoothing = fwidth(msdf.a) * 0.5;
    float alpha = smoothstep(0.5 - smoothing, 0.5 + smoothing, dist);

    if (alpha <= 0.01) {
        discard;
    }

    out_color = vec4(in_color.rgb, in_color.a * alpha);
}
#endif // FRAGMENT
