#version 450

#ifdef VERTEX
layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_cam_pos;
    vec4 u_cam_right;
    vec4 u_cam_up;
    float u_time;
};
#endif // VERTEX

#ifdef FRAGMENT
layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_time;
};
#endif // FRAGMENT

#ifdef GRAPHICS_MAIN
layout(location = 0) IO Interface {
vec3 position;
vec3 normal;
vec3 emissive;
} io;
#endif // GRAPHICS_MAIN

#ifdef VERTEX_MAIN
layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

layout(location = 8) in vec4 in_inst_translation_scale;
layout(location = 9) in vec4 in_inst_rotation;
layout(location = 10) in vec4 in_inst_emissive;

#include <transform.glsl>

void main() {
    vec3 cam_position = u_cam_pos.xyz;

    const float scale = in_inst_translation_scale.w;
    const vec3 translation = in_inst_translation_scale.xyz;
    const vec4 rotation = in_inst_rotation;
    vec3 rotated_position = rotateVector(in_position, rotation) * scale;
    vec3 translated_position = rotated_position + translation;

    io.position = translated_position - cam_position;
    io.normal = rotateVector(in_normal, rotation);
    io.emissive = in_inst_emissive.rgb * in_inst_emissive.a;

    vec4 clip_position = u_view_projection * vec4(translated_position, 1.);
    gl_Position = clip_position;
}
#endif // VERTEX_MAIN

#ifdef FRAGMENT_MAIN
layout(location = 0) out vec4 out_color;

void main() {
    vec3 dir = normalize(-io.position);
    float lighting = max(dot(dir, io.normal), 0.5);
    out_color = vec4(lighting * io.emissive, 1.0);
}
#endif // FRAGMENT_MAIN
