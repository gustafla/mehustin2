# Next-gen Mehu Demo Engine

This is a [demo](https://en.wikipedia.org/wiki/Demoscene) engine for creating
audiovisual programs that utilize the GPU for rendering graphics.

:warning: Unstable API, ongoing development. :construction:

Based on SDL3 GPU API and glslc, implemented in [Zig](https://ziglang.org).

**Features**:
- Render and compute pipeline abstraction.
- Timeline abstraction and camera management.
- Data-driven render graphs via Zig's `comptime` ZON parsing,
  implemented entirely with `comptime` reflection.
- Runtime dynamic reloading while editing.
- Shader library and `#include` support.
- Ogg/vorbis music tracks (with BPM time synchronization).
- Text rendering with SDF fonts.
- Seamless multiplatform builds.

## Quickstart

You can run the included example project:
```
cd example
zig build run
```

**Note**: Running `zig build` straight from the root of this repository will
only build a dummy binary.

## Using as a Dependency

To build your own demo, the engine must be built together with a "script"
module that drives the demo's resources and logic.
See the example [build.zig](example/build.zig) file for reference.

Add this package to your Zig project:
```
zig fetch --save=mehustin2 https://github.com/.../vx.y.z.tar.gz
```
(using the URL of the latest [release](https://github.com/gustafla/mehustin2/releases))

**Build-time system dependencies**:
- Zig 0.16.0
- glslc
- freetype2
- libpng

**External projects using the engine**:
- (unmaintained) [Abyss by Mehu](https://github.com/gustafla/abyss)

## Supported Platforms

Requires SPIR-V shader support. Essentially, requires Vulkan, as this project
doesn't include a shader cross-compiler.

Developed on GNU/Linux (i.e. `-Dtarget=x86_64-linux-gnu`), but can be
built for, and run on `x86_64-windows-gnu` and `aarch64-linux-gnu` as well.

Special care has been taken to support low-spec Linux devices running Wayland
compositors, a zero-copy path exists for fullscreen output.

## Dynamic Reloading

When built with `-Drender_dynlib=true` (default for `-Doptimize=Debug`), the
renderer and its shaders, assets and compiled parameters can be hot-reloaded
by pressing **R** when the demo preview window is in focus.

Combine this with `zig build --watch` for the best development experience!

## Shader Interface

The shader interface follows the SDL3 GPU requirements, described here:
https://wiki.libsdl.org/SDL3/SDL_CreateGPUShader

Uniforms are hardcoded, see [types.zig](src/engine/types.zig) for definitions.
Any number of SSBOs, vertex and instance buffers can be bound to the pipeline
via the script module.

## License

This engine is available under the [zlib License](LICENSE).

For third-party open source component licenses,
see [vendor/LICENSES.md](vendor/LICENSES.md).
