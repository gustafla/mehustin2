#version 450

layout(location = 0) in vec2 FragCoord;
layout(location = 0) out vec4 FragColor;

layout(set = 2, binding = 0) uniform sampler2D u_InputTexture;
layout(set = 2, binding = 1) uniform sampler2D u_NoiseTexture;

layout(set = 3, binding = 0) uniform PushConstants {
    vec2 u_Resolution;
    float u_Time;
};

#include <lib/color.glsl>

vec3 bright(vec2 uv) {
    return max(texture(u_InputTexture, uv).rgb - 1., 0.);
}

void main() {
    vec2 uv = FragCoord * 0.5 + 0.5;

    // Chromatic aberration
    vec3 color = vec3(
            texture(u_InputTexture, uv + vec2(-1. / u_Resolution.x, 0.)).r,
            texture(u_InputTexture, uv).g,
            texture(u_InputTexture, uv + vec2(1. / u_Resolution.x, 0.)).b
        );

    // Radial blur
    for (int i = 0; i < 64; i++) {
        float prog = float(i) / 64.;
        color += bright((FragCoord / (1 + prog)) * 0.5 + 0.5) * (1. / 32.) * (1 - prog);
    }

    // Vignette
    color = color - length(FragCoord) * 0.2;

    // Noise
    float noise_amount = 0.06;
    ivec2 noise_uv = ivec2(gl_FragCoord.xy) % 64;
    color += texelFetch(u_NoiseTexture, noise_uv, 0).r * noise_amount;

    // Output
    // https://64.github.io/tonemapping/
    FragColor = vec4(acesApprox(max(color, 0.)), 1.);
}
