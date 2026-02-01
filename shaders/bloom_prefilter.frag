#version 450

layout(location = 0) in vec2 in_uv;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_input_texture;

#define THRESHOLD 6.0
#define KNEE 2
#define EPSILON 0.00001

#include <lib/color.glsl>

// https://www.desmos.com/calculator/0cw6zqclwh

void main() {
    vec3 color = texture(u_input_texture, in_uv).rgb;
    color = clamp(color, 0.0, 10.0);

    float luma = brightness(color);
    float soft = luma - THRESHOLD + KNEE;
    soft = clamp(soft, 0.0, 2.0 * KNEE);
    soft = soft * soft / (4.0 * KNEE + EPSILON);

    float contribution = max(soft, luma - THRESHOLD);
    contribution /= max(luma, EPSILON);

    out_color = vec4(color * contribution, 1.0);
}
