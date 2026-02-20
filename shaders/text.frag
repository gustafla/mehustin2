#version 450

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

#include <lib/noise.glsl>

void main() {
    vec3 coord = vec3(in_uv, float(in_style.x));

    switch (in_style.y) {
        case 1: // UV ripple
        coord.x += noise(coord.xy * 200 + u_time_g) * 0.004;
        coord.y += noise(coord.xy * 200 + 123 - u_time_g) * 0.004;
        break;
    }

    float dist = texture(u_font_atlas, coord).r;

    float smoothing = fwidth(dist) * 0.5;
    float alpha = smoothstep(0.5 - smoothing, 0.5 + smoothing, dist);

    if (alpha <= 0.01) {
        discard;
    }

    out_color = vec4(in_color.rgb, in_color.a * alpha);
}
