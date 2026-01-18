#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec2 in_ndc;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_input_texture;
layout(set = 2, binding = 1) uniform sampler2D u_blur_texture;
layout(set = 2, binding = 2) uniform sampler2D u_noise_texture;

#include <lib/color.glsl>

vec3 bright(vec2 uv) {
    return max(texture(u_input_texture, uv).rgb - 1., 0.);
}

vec2 ndc_to_uv(vec2 ndc) {
    return vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
}

void main() {
    // Chromatic aberration
    vec3 color = vec3(
            texture(u_input_texture, in_uv + vec2(-1. / WIDTH, 0.)).r,
            texture(u_input_texture, in_uv).g,
            texture(u_input_texture, in_uv + vec2(1. / WIDTH, 0.)).b
        );

    // Radial blur
    for (int i = 0; i < 64; i++) {
        float prog = float(i) / 64.;
        vec2 scaled_ndc = in_ndc / (1.0 + prog);
        color += bright(ndc_to_uv(scaled_ndc)) * (1. / 32.) * (1. - prog);
    }

    // Kawase blur
    color += texture(u_blur_texture, in_uv).rgb;

    // Vignette
    color = color - length(in_ndc) * 0.2;

    // Noise
    float noise_amount = 0.06;
    ivec2 noise_uv = ivec2(gl_FragCoord.xy) % 64;
    color += texelFetch(u_noise_texture, noise_uv, 0).r * noise_amount;

    // Output
    // https://64.github.io/tonemapping/
    out_color = vec4(acesApprox(max(color, 0.)), 1.);
}
