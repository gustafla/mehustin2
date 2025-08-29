#version 450

layout(location = 0) in vec2 FragCoord;
layout(location = 0) out vec4 FragColor;

layout(set = 2, binding = 0) uniform sampler2D u_InputTexture;

layout(set = 3, binding = 0) uniform PushConstants {
    vec2 u_Resolution;
    float u_Time;
};

#include <lib/noise.glsl>
#include <lib/color.glsl>

void main() {
    vec2 uv = FragCoord * 0.5 + 0.5;

    // Chromatic aberration
    vec3 color = vec3(
            texture(u_InputTexture, uv + vec2(-1. / u_Resolution.x, 0.)).r,
            texture(u_InputTexture, uv).g,
            texture(u_InputTexture, uv + vec2(1. / u_Resolution.x, 0.)).b
        );

    // Vignette
    color = color - length(FragCoord) * 0.2;

    // Noise
    float noise_amount = 0.06;
    vec2 seed = gl_FragCoord.xy;
    seed += vec2(noise(u_Time * 5.), noise(u_Time * 11.)) * u_Resolution;
    color += (noise(seed) - .5) * noise_amount;

    // Output
    // https://64.github.io/tonemapping/
    FragColor = vec4(acesApprox(max(color, 0.)), 1.);
}
