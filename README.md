# Next-gen Mehu demo engine

## Building

Currently, the engine cannot be built from this repository, as it requires a
"script" module which drives the demo's resources and logic.

Build dependencies:
- Zig 0.15.2
- glslc
- SDL3 (optional, use `-Dsystem_sdl=false` to build a static library)

Example project (outdated): See [Abyss](https://github.com/gustafla/abyss).

## Dynamic Reloading

When built with `-Drender_dynlib=true` (default for `-Doptimize=Debug`), the
renderer and it's shaders, assets and compiled parameters can be hot-reloaded
by pressing R when the demo preview window is in focus.

## Shader Interface

The shader interface follows the SDL3 GPU requirements, described here:
https://wiki.libsdl.org/SDL3/SDL_CreateGPUShader

Uniforms are hardcoded, see [types.zig](src/engine/types.zig) for definitions.
Any number of SSBOs, vertex and instance buffers can be bound to the pipeline
via the script module.

## License

This engine is released under the [zlib License](LICENSE).
