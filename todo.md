# High priority

- [ ] 3D instance render & shaders
  - [ ] Lighting (directional)
  - [ ] Lighting (point light sources)
- [ ] Particle rendering
- [ ] Developer controls
  - [X] Time
  - [ ] Cameras
- [ ] Clip sequencing
  - [ ] Transitions
- [ ] Parameter tracks
- [ ] Camera tracks
- [ ] Scene state

# Backlog

- [ ] Build-time font generation
- [ ] Complete build-time asset pipeline (texture compression, audio encoding etc.)
- [ ] Compute passes
- [ ] `tri.frag`: Add corner rays for interpolator
- [ ] MSAA with resolve texture
- [ ] DoF
  - [ ] Bokeh sprites
- [ ] HDR textures from file
- [ ] Render scene to cubemap
- [ ] Text mesh rendering
  - [ ] libtess2
- [ ] imgui (dear_imgui_zig)
- [ ] More physically accurate chromatic aberration
  - refract(), multiple channels
  - https://gist.github.com/jjcastro/10bf80b5a5c740056b461f3010787ec1
- [ ] Color grading LUT https://www.youtube.com/shorts/TYx5SgEGemc
- [ ] Marching cubes
- [ ] Particle simulations
- [ ] Use (games-by-mason) libraries?
  - [ ] Zex
  - [ ] shader_compiler
  - [ ] tracy_zig
  - [ ] Tween
  - [ ] dear_imgui_zig
  - [ ] gbms
  - [ ] zm
- [ ] Add pass chain macro to render.zon syntax

# Done

- [X] Refactor render.zig init for shared texture/buffer upload logic
- [X] Dynamic text buffers
- [X] Procedural mesh generation
- [X] Add option to have `store_op = .dont_care` for depth targets
- [X] Dual Kawase blur
  - https://blog.frost.kiwi/dual-kawase/
  - [X] Bloom
- [X] Remove uniform bindings from render config (https://wiki.libsdl.org/SDL3/CategoryGPU#uniform-data)
- [X] Sampler configuration (sampler set)
- [X] Write comptime function for generating Zig enums from SDL GPU enums
- [X] Blending
- [X] Text SDF rendering
  - [X] stb_truetype
- [X] Textures
  - [X] Color target
  - [X] Depth target
  - [X] RGBA from file
  - [X] Simplex noise
- [X] Post processing
- [X] Music player
- [X] Render abstractions
  - [X] Pass for post processing
  - [X] Mesh
  - [X] Instances
  - [X] Uniforms
- [X] Dynamic library reloading
  - [X] Shader live editing
  - [ ] Improve error handling
    - [X] Keep running when errors
    - [ ] Report error codes over FFI boundary
  - [ ] TODO: https://github.com/ziglang/zig/issues/25026
