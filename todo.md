# High priority

- [ ] Dual Kawase blur
  - https://blog.frost.kiwi/dual-kawase/
  - [ ] Bloom
- [ ] Dynamic text buffers
- [ ] Particle rendering
- [ ] Procedural mesh generation
- [ ] Developer controls
  - [X] Time
  - [ ] Cameras
- [ ] Sequencing
  - [ ] Transitions
- [ ] Sync system
  - [ ] Camera tracks
  - [ ] Parameter tracks

# Backlog

- [ ] `tri.frag`: Add corner rays for interpolator
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
 - [ ] Refactor render.zig init for shared texture/buffer upload logic

# Done

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
