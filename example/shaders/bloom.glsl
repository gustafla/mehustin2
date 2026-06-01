#version 450

layout(location = 0) in vec2 in_uv;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_input_texture;

#if defined(PREFILTER)
#if !defined(BLOOM_PRE_THRESHOLD)
#define BLOOM_PRE_THRESHOLD 2.0
#endif
#if !defined(BLOOM_PRE_KNEE)
#define BLOOM_PRE_KNEE 2.0
#endif

#define EPSILON 0.00001

#include <color.glsl>

// https://www.desmos.com/calculator/0cw6zqclwh

void main() {
    vec3 color = texture(u_input_texture, in_uv).rgb;

    float luma = brightness(color);
    float soft = luma - BLOOM_PRE_THRESHOLD + BLOOM_PRE_KNEE;
    soft = clamp(soft, 0.0, 2.0 * BLOOM_PRE_KNEE);
    soft = soft * soft / (4.0 * BLOOM_PRE_KNEE + EPSILON);

    float contribution = max(soft, luma - BLOOM_PRE_THRESHOLD);
    contribution /= max(luma, EPSILON);

    out_color = vec4(color * contribution, 1.0);
}
#endif // PREFILTER

#if defined(JIMENEZ)
void main() {
    vec2 t = 1.0 / textureSize(u_input_texture, 0);
    #if defined(PIXEL_SCALE)
    t *= PIXEL_SCALE;
    #endif

    vec4 sum = vec4(0.0);

    #if defined(UP)
    const float weight = 1.0 / 16.0;
    sum += texture(u_input_texture, in_uv + vec2(-1.0, 1.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(0.0, 1.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, 1.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(-1.0, 0.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(0.0, 0.0) * t) * 4.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, 0.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(-1.0, -1.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(0.0, -1.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, -1.0) * t);
    #elif defined(DOWN)
    const float weight = 1.0 / 32.0;
    sum += texture(u_input_texture, in_uv + vec2(-2.0, 2.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(0.0, 2.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(2.0, 2.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(-2.0, 0.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(0.0, 0.0) * t) * 4.0;
    sum += texture(u_input_texture, in_uv + vec2(2.0, 0.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(-2.0, -2.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(0.0, -2.0) * t) * 2.0;
    sum += texture(u_input_texture, in_uv + vec2(2.0, -2.0) * t);
    sum += texture(u_input_texture, in_uv + vec2(-1.0, 1.0) * t) * 4.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, 1.0) * t) * 4.0;
    sum += texture(u_input_texture, in_uv + vec2(-1.0, -1.0) * t) * 4.0;
    sum += texture(u_input_texture, in_uv + vec2(1.0, -1.0) * t) * 4.0;
    #else
    #error "Either UP or DOWN must be defined"
    #endif // UP elif DOWN

    out_color = sum * weight;
}
#endif // JIMENEZ
