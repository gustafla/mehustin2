#version 450
#extension GL_EXT_samplerless_texture_functions: require

#if defined(VERTEX)
layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_cam_pos;
    vec4 u_cam_right;
    vec4 u_cam_up;
    float u_time;
};
#endif // VERTEX

#if defined(FRAGMENT)
layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_time;
};
#endif // FRAGMENT

#if defined(VERTEX_MAIN) || defined(FRAGMENT_MAIN)
layout(location = 0) IO Interface {
vec3 position;
vec3 normal;
vec3 emissive;
} io;
#endif // VERTEX_MAIN or FRAGMENT_MAIN

#if defined(VERTEX_MAIN)
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

layout(location = 8) in vec4 in_inst_translation_scale;
layout(location = 9) in vec4 in_inst_rotation;
layout(location = 10) in vec4 in_inst_emissive;

#include <transform.glsl>

void main() {
    vec3 cam_position = u_cam_pos.xyz;

    const float scale = in_inst_translation_scale.w;
    const vec3 translation = in_inst_translation_scale.xyz;
    const vec4 rotation = in_inst_rotation;
    vec3 rotated_position = rotateVector(in_position, rotation) * scale;
    vec3 translated_position = rotated_position + translation;

    io.position = translated_position - cam_position;
    io.normal = rotateVector(in_normal, rotation);
    io.emissive = in_inst_emissive.rgb * in_inst_emissive.a;

    vec4 clip_position = u_view_projection * vec4(translated_position, 1.);
    gl_Position = clip_position;
}
#endif // VERTEX_MAIN

#if defined(FRAGMENT_MAIN)
layout(location = 0) out vec4 out_color;

void main() {
    vec3 dir = normalize(-io.position);
    float lighting = max(dot(dir, io.normal), 0.5);
    out_color = vec4(lighting * io.emissive, 1.0);
}
#endif // FRAGMENT_MAIN

#if defined(FRAGMENT_POST)
layout(location = 0) in vec2 in_uv;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_input_texture;
layout(set = 2, binding = 1) uniform sampler2D u_bloom_texture;

#include <color.glsl>

void main() {
    vec3 color = texture(u_input_texture, in_uv).rgb;

    // Bloom
    color = texture(u_bloom_texture, in_uv).rgb;
    out_color = vec4(reinhard(max(color, 0.)), 1.);
}
#endif // FRAGMENT_POST

#if defined(COMPUTE_NAIVE_CONVOLUTION)
layout(local_size_x = DIM_TOTAL_X, local_size_y = DIM_TOTAL_Y) in;

layout(set = 0, binding = 0) uniform texture2D in_texture;
layout(set = 1, binding = 0, rgba16f) writeonly uniform image2D out_texture;

void main() {
    ivec2 texel_coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 img_size = textureSize(in_texture, 0);

    if (texel_coord.x >= img_size.x || texel_coord.y >= img_size.y) {
        return;
    }

    vec4 sum = vec4(0.0);
    float coeff = 1.0 / (DIM_TOTAL_X * DIM_TOTAL_Y);

    for (int y = 0; y < DIM_TOTAL_Y; y++) {
        for (int x = 0; x < DIM_TOTAL_X; x++) {
            ivec2 sample_coord = texel_coord + ivec2(x - DIM_TOTAL_X / 2, y - DIM_TOTAL_Y / 2);
            sample_coord = clamp(sample_coord, ivec2(0, 0), img_size - 1);
            sum += coeff * texelFetch(in_texture, sample_coord, 0);
        }
    }

    imageStore(out_texture, texel_coord, sum);
}
#endif // COMPUTE_NAIVE_CONVOLUTION
