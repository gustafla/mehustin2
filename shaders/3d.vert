#version 450

layout(location = 0) in vec3 a_Position;
layout(location = 2) in vec3 a_Color;

layout(set = 1, binding = 0) uniform Matrices {
    mat4 u_Projection;
    mat4 u_View;
};

layout(set = 1, binding = 1) uniform PushConstants {
    vec2 u_Resolution;
    float u_Time;
};

layout(location = 0) out vec3 Color;

#include <lib/noise.glsl>

mat4 model() {
    mat4 m = mat4(
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        );

    if (u_Time > 14.) {
        float i = gl_InstanceIndex * 1024.213 + 23321.;
        m[3].x = noise(i + 0) * 64. - 32.;
        m[3].y = noise(i + 1) * 64. - 32.;
        m[3].z = noise(i + 2) * 64. - 32.;
    }

    return m;
}

void main() {
    vec4 pos = u_View * model() * vec4(a_Position, 1.);
    Color = a_Color;
    gl_Position = u_Projection * pos;
}
