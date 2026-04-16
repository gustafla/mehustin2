# Next-gen Mehu Demo Engine

This is a [demo](https://en.wikipedia.org/wiki/Demoscene) engine for creating
audiovisual programs that utilize the GPU for rendering graphics.

:warning: Unstable API, ongoing development. :construction:

Based on SDL3 GPU API and glslc, implemented in [Zig](https://ziglang.org).

**Features**:
- Render and compute pipeline abstraction
- Timeline abstration, cameras
- Based on Zig's compile-time ZON file parsing: `@import("render.zon")`
- Implemented entirely with `comptime` reflection and explicit inlining
- Runtime dynamic reloading while editing
- Shader library and `#include` support
- Ogg/vorbis music tracks (with bpm time)
- Text rendering with SDF fonts
- Seamless multiplatform builds

## Build and Usage

The engine is built together with a "script" module which drives the demo's
resources and logic. See the [example build.zig file](example/build.zig).

Running `zig build` straight from the root of this repository should result in
errors about the missing "script" module. Instead, use this as a dependency,
i.e. `zig fetch --save=mehustin2 https://github.com/.../vx.y.z.tar.gz` (using
the URL to the latest [release](https://github.com/gustafla/mehustin2/releases)
source code).

Build-time system dependencies:
- Zig 0.16.0
- glslc
- freetype2
- libpng

Example projects:
- The repository example:
  ```
  cd example
  zig build run
  ```
- (unmaintained) [Abyss by Mehu](https://github.com/gustafla/abyss)

## Supported Platforms

Requires SPIR-V shader support (essentially, requires Vulkan).
Developed on GNU/Linux (i.e. `-Dtarget=x86_64-linux-gnu`), but can be
built for, and run on `x86_64-windows-gnu` and `aarch64-linux-gnu` as well.

Special care has been taken to support low-spec Linux devices running Wayland
compositors, a zero-copy path exists for fullscreen output.

## Dynamic Reloading

When built with `-Drender_dynlib=true` (default for `-Doptimize=Debug`), the
renderer and it's shaders, assets and compiled parameters can be hot-reloaded
by pressing R when the demo preview window is in focus.

Combine this with `zig build --watch` for best results!

## Shader Interface

The shader interface follows the SDL3 GPU requirements, described here:
https://wiki.libsdl.org/SDL3/SDL_CreateGPUShader

Uniforms are hardcoded, see [types.zig](src/engine/types.zig) for definitions.
Any number of SSBOs, vertex and instance buffers can be bound to the pipeline
via the script module.

## License

This engine is available under the [zlib License](LICENSE).

For the third party open source component licenses,
see [vendor/LICENSES.md](vendor/LICENSES.md).
