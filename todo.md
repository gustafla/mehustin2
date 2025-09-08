# High priority

- [ ] Textures
  - [X] Color target
  - [ ] Depth target
  - [X] RGBA from file
  - [ ] HDR from file
  - [ ] Simplex noise
- [ ] Dual Kawase blur
  - [ ] Bloom
  - [ ] DoF
    - [ ] Bokeh sprites
- [ ] Text mesh rendering
  - [ ] stb_truetype
  - [ ] libtess2
- [ ] Developer controls
  - [X] Time
  - [ ] Cameras
- [ ] Sequencing
  - [ ] Transitions
- [ ] Sync system
  - [ ] Camera tracks
  - [ ] Parameter tracks

# Backlog

- [ ] imgui
- [ ] More physically accurate chromatic aberration
  - refract(), multiple channels
  - https://gist.github.com/jjcastro/10bf80b5a5c740056b461f3010787ec1
- [ ] Color grading LUT https://www.youtube.com/shorts/TYx5SgEGemc
- [ ] Use (games-by-mason) libraries?
  - [ ] Zex
  - [ ] shader_compiler
  - [ ] tracy_zig
  - [ ] Tween
  - [ ] dear_imgui_zig
  - [ ] gbms
  - [ ] zm

# Done

- [X] Post processing
- [X] Music player
- [X] Render abstractions
  - [X] Pass for post processing
  - [X] Mesh
  - [ ] Instances
  - [X] Uniforms
- [X] Dynamic library reloading
  - [X] Shader live editing
  - [ ] Improve error handling
    - [X] Keep running when errors
    - [ ] Report error codes over FFI boundary
  - [ ] TODO: https://github.com/ziglang/zig/issues/25026
