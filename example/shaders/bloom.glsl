#version 450
#extension GL_EXT_samplerless_texture_functions: require

#include <generated_data.glsl>

const int M = 100;
const int N = M * 2 + 1;

#if defined(COMPUTE)
layout(local_size_x = DIM_TOTAL_X, local_size_y = DIM_TOTAL_Y) in;

layout(set = 0, binding = 0) uniform texture2D in_texture;
layout(set = 1, binding = 0, rgba16f) writeonly uniform image2D out_texture;
#endif // COMPUTE

#if defined(COMPUTE_NAIVE_CONVOLUTION)
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

#if defined(COMPUTE_SEPARABLE_HORIZONTAL) || defined(COMPUTE_SEPARABLE_VERTICAL)
void main() {
    ivec2 texel_coord = ivec2(gl_GlobalInvocationID.xy);
    ivec2 img_size = textureSize(in_texture, 0);

    if (texel_coord.x >= img_size.x || texel_coord.y >= img_size.y) {
        return;
    }

    vec4 sum = vec4(0.0);

    for (int i = 0; i < N; i++) {
        int i_minus_m = i - M;

        #if defined(SEPARABLE_HORIZONTAL)
        ivec2 sample_coord = ivec2(texel_coord.x + i_minus_m, texel_coord.y);
        #else
        ivec2 sample_coord = ivec2(texel_coord.x, texel_coord.y + i_minus_m);
        #endif

        sample_coord = clamp(sample_coord, ivec2(0, 0), img_size - 1);
        sum += kernel_gaussian101[abs(i_minus_m)] * texelFetch(in_texture, sample_coord, 0);
    }

    imageStore(out_texture, texel_coord, sum);
}
#endif // COMPUTE_SEPARABLE_HORIZONTAL or COMPUTE_SEPARABLE_VERTICAL

#if defined(COMPUTE_SEPARABLE_HORIZONTAL_CACHE) || defined(COMPUTE_SEPARABLE_VERTICAL_CACHE)
#if (DIM_TOTAL_X != DIM_TOTAL_Y || DIM_TOTAL_Z != 1)
#error "This shader must be compiled for a square workgroup"
#endif

const int cache_s = DIM_TOTAL_Y;
const int cache_l = DIM_TOTAL_X + M * 2;
shared vec4 cache[cache_s][cache_l];

void main() {
    const ivec2 texel_coord = ivec2(gl_GlobalInvocationID.xy);
    const ivec2 img_size = textureSize(in_texture, 0);

    const ivec2 tile_base = ivec2(gl_WorkGroupID.xy) * DIM_TOTAL_X;
    #if defined(SEPARABLE_HORIZONTAL_CACHE)
    const ivec2 cc = ivec2(gl_LocalInvocationID.yx);
    #else
    const ivec2 cc = ivec2(gl_LocalInvocationID.xy);
    #endif

    const int num_load_tiles = (cache_l + DIM_TOTAL_X - 1) / DIM_TOTAL_X;
    for (int i = 0; i < num_load_tiles; i++) {
        const ivec2 cc_load = ivec2(i * DIM_TOTAL_X, 0) + cc;

        if (cc_load.x >= cache_l) break;

        #if defined(SEPARABLE_HORIZONTAL_CACHE)
        const ivec2 sample_coord = tile_base + cc_load - ivec2(M, 0);
        #else
        const ivec2 sample_coord = tile_base + cc_load.yx - ivec2(0, M);
        #endif

        sample_coord = clamp(sample_coord, ivec2(0, 0), img_size - 1);
        cache[cc_load.y][cc_load.x] = texelFetch(in_texture, sample_coord, 0);
    }

    barrier();

    if (texel_coord.x >= img_size.x || texel_coord.y >= img_size.y) {
        return;
    }

    vec4 sum = vec4(0.0);

    for (int i = 0; i < N; i++) {
        sum += kernel_gaussian101[abs(i - M)] * cache[cc.x][cc.y + i];
    }

    imageStore(out_texture, texel_coord, sum);
}
#endif // COMPUTE_SEPARABLE_HORIZONTAL_CACHE or COMPUTE_SEPARABLE_VERTICAL_CACHE
