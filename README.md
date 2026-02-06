# Next-gen Mehu demo engine

## Dynamic Reloading

When built with `-Drender-dynlib=true` (default for `-Doptimize=Debug`), the
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

Total uniform (push constant) size: 92 bytes (each binding padded to 16 bytes).

*Macros:*
The following macros are defined at shader compilation in the build process:
```glsl
#define WIDTH config.width
#define HEIGHT config.height
#define MAX_LIGHTS config.max_lights // Safety clamp for light iteration
```

## Model Vertices, Translation, Rotation and Scale

All models are rendered instanced, the engine doesn't use a model matrix.
Model parameters are instance attributes.

Buffer layouts (both vertex and instance) can be defined in `script.zig`.
The system is designed for tightly packed interleaved data, only one vertex
buffer and one instance buffer, but as many interleaved attributes as the API
can support (at least 16).

Here are recommended layouts:
```glsl
// Vertex Attributes:
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_tangent;
layout(location = 3) in vec3 in_color;
layout(location = 4) in vec2 in_uv0;
layout(location = 5) in vec2 in_uv1;

// Instance Attributes (3D rendering):
layout(location = 8) in vec4 in_instance_pos_scale; // .xyz = pos, .w = scale
layout(location = 9) in vec4 in_instance_rot_quat;  // Quaternion

// Instance Attributes (text rendering):
layout(location = 8) in vec4 in_instance_uv;        // xy = min, zw = max
layout(location = 9) in vec4 in_instance_position;  // xy = min, zw = max
layout(location = 10) in vec4 in_instance_color;
```

## Coordinate System

Coordinates in the world- and view spaces are right-handed, Y-up.

All vertex- and instance inputs in the render pipeline are in world coordinates.
The view_projection matrix has a translation component, which transforms
to view space. The camera position is provided in the vertex shader uniforms for
camera-relative lighting.

## Scripting and Plugging Render Resources to the Renderer

TODO: Write this section when the design is stabilized. 

## Demo Orchestration

Time is in musical beats, BPM is configurable in `config.zon`.

The `timeline.zon` file contains various tracks:

- `clip_track`: For switching the currently active logic (`script.zig`) and
  filtering the frame graph (`render.zon`).
- `camera.tracks`: A domain-specific language for camera pathing (`camera.zig`).
- `camera.control`: For selecting between multiple tracks and locking on anchors
- `camera.effects`: Camera effects overlaid on top of the main track.

## Extra Data, Lighting

The engine supports any number of storage buffers (SSBOs), see `script.zig`.

For example, light source data can be provided to the shaders using an SSBO:
```glsl
layout(std430, set = 2, binding = X) readonly buffer LightData {
    vec4 u_sun_direction_intensity;
    vec4 u_sun_color_ambient;
    uint num_point_lights;
    uint _pad[3];
    // Even index: Camera-relative position (xyz) + Radius (w)
    // Odd index:  Light color (rgb)              + Padding (w)
    vec4 pos_color_interleaved[];
};
```

When a sync track system is implemented, all shaders get an SSBO with the
current frame's interpolated sync parameter values.
There are 64 floating point tracks available, i.e.:
```glsl
layout(std430, set = 2, binding = X) readonly buffer SyncData {
    float tracks[64];
};
```
