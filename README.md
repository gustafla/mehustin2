# Next-gen Mehu demo engine

## Dynamic reloading

When built with `-Drender-dynlib=true` (default for `-Doptimize=Debug`), the
renderer and it's shaders, assets and compiled parameters can be hot-reloaded
by pressing R when the demo preview window is in focus.

## Camera-Relative Rendering

All input coordinates in the render pipeline are camera-relative, i.e.
pre-translated so that the camera position is always at `vec3(0, 0, 0)`.
The view matrix does not include a translation component.
However, to enable procedural instance generation, the camera position is
provided in the vertex shader uniforms.

## Shader Interface

The shader interface follows the SDL3 GPU requirements, described here:
https://wiki.libsdl.org/SDL3/SDL_CreateGPUShader

*Vertex Shader Uniforms:*
```glsl
layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_camera_position;
    float u_time;
};
```

*Fragment Shader Uniforms:*
```glsl
layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    vec4 u_sun_direction_intensity;
    vec4 u_sun_color_ambient;
    float u_time;
};

layout(std140, set = 3, binding = 1) uniform FragmentPassData {
    float u_target_scale;
};
```

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

Buffer layouts (both vertex and instance) can be defined in `render.zon`.
The system is designed for tightly packed interleaved data, only one vertex
buffer and one instance buffer, but as many interleaved attributes as the API
can support (at least 16).

Here is a recommended layout:
```glsl
// Vertex Attributes:
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec3 in_color;
layout(location = 3) in vec2 in_uv;
layout(location = 4) in vec3 in_tangent;
layout(location = 5) in vec3 in_bitangent;

// Instance Attributes (3D rendering):
layout(location = 6) in vec4 in_instance_pos_scale; // .xyz = pos, .w = scale
layout(location = 7) in vec4 in_instance_rot_quat;  // Quaternion

// Instance Attributes (text rendering):
layout(location = 6) in vec4 in_instance_uv;        // xy = min, zw = max
layout(location = 7) in vec4 in_instance_position;  // xy = min, zw = max
layout(location = 8) in vec4 in_instance_color;
```

## Extra Lighting

When implemented, point light data will be provided to the fragment shaders in
an SSBO:
```glsl
layout(std430, readonly, set = 2, binding = X) buffer PointLightData {
    uint num_point_lights;
    uint _pad[3];
    // Even index: Camera-relative position (xyz) + Radius (w)
    // Odd index:  Light color (rgb)              + Padding (w)
    vec4 pos_color_interleaved[];
};
```

## Sync Automation

When implemented, all shaders get an SSBO with the current frame's interpolated
sync parameter values. There are 64 floating point tracks available, i.e.:
```glsl
layout(std430, readonly, set = 2, binding = X) buffer SyncData {
    float tracks[64];
};
```
