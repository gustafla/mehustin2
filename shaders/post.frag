#version 450

layout(location = 0) in vec2 in_uv;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_input_texture;
layout(set = 2, binding = 1) uniform sampler2D u_bloom_texture;
layout(set = 2, binding = 2) uniform sampler2D u_noise_texture;

#include <lib/color.glsl>

void main() {
    vec3 color = texture(u_input_texture, in_uv).rgb;

    // Bloom
    color += texture(u_bloom_texture, in_uv).rgb * 2.;

    // Vignette
    color = color - length(in_uv - vec2(0.5)) * 0.4;

    // Noise
    float noise_amount = 0.06;
    ivec2 noise_uv = ivec2(gl_FragCoord.xy) % 64;
    color += texelFetch(u_noise_texture, noise_uv, 0).r * noise_amount;

    // Output
    // https://64.github.io/tonemapping/
    out_color = vec4(acesApprox(max(color, 0.)), 1.);
    // out_color = vec4(reinhard(max(color, 0.)), 1.);
}
