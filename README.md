# Next-gen Mehu demo engine

## Building

Currently, the engine cannot be built from this repository, as it requires a
"script" module which drives the demo's resources and logic.

Build dependencies:
- Zig 0.15.2
- glslc
- SDL3 (optional, use `-Dsystem_sdl=false` to build a static library)

Example project: See [Abyss](https://github.com/gustafla/abyss).

## Dynamic Reloading

When built with `-Drender_dynlib=true` (default for `-Doptimize=Debug`), the
renderer and it's shaders, assets and compiled parameters can be hot-reloaded
by pressing R when the demo preview window is in focus.

## Shader Interface

The shader interface follows the SDL3 GPU requirements, described here:
https://wiki.libsdl.org/SDL3/SDL_CreateGPUShader

*Vertex Shader Uniforms:*
```glsl
layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_camera_position;
    vec4 u_camera_right;
    vec4 u_camera_up;
    float u_global_time;
};
```

*Fragment Shader Uniforms:*
```glsl
layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_global_time;
    float u_clip_time;
    float u_clip_remaining_time;
};

layout(std140, set = 3, binding = 1) uniform FragmentPassData {
    float u_target_scale;
};
```

## License

This engine is released under the [zlib License](LICENSE).
