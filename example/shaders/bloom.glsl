#version 450
#extension GL_EXT_samplerless_texture_functions: require

#if defined(NAIVE_CONVOLUTION) || \
    defined(SEPARABLE_HORIZONTAL) || \
    defined(SEPARABLE_VERTICAL) || \
    defined(SEPARABLE_SINGLE_PASS)
const int M = 100;
const int N = M * 2 + 1;
#endif // NAIVE or VERTICAL or HORIZONTAL or SINGLE_PASS

#if defined(COMPUTE_NAIVE_CONVOLUTION)
layout(local_size_x = DIM_TOTAL_X, local_size_y = DIM_TOTAL_Y) in;

layout(set = 0, binding = 0) uniform texture2D in_texture;
layout(set = 1, binding = 0, rgba16f) writeonly uniform image2D out_texture;

#include <generated_data.glsl>

void main() {
    ivec2 texel_coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 img_size = textureSize(in_texture, 0);

    if (texel_coord.x >= img_size.x || texel_coord.y >= img_size.y) {
        return;
    }

    vec4 sum = vec4(0.0);

    for (int y = 0; y < N; y++) {
        for (int x = 0; x < N; x++) {
            ivec2 offset = ivec2(x - M, y - M);
            ivec2 sample_coord = texel_coord + offset;
            sample_coord = clamp(sample_coord, ivec2(0, 0), img_size - 1);
            sum += kernel_gaussian101[abs(offset.x)] *
                    kernel_gaussian101[abs(offset.y)] *
                    texelFetch(in_texture, sample_coord, 0);
        }
    }

    imageStore(out_texture, texel_coord, sum);
}
#endif // COMPUTE_NAIVE_CONVOLUTION
