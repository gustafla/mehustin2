#version 450

layout(location = 0) in vec3 in_position;
layout(location = 2) in vec3 in_color;

layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_cam_pos;
    float u_time;
};

layout(location = 0) out vec3 out_color;

#include <lib/noise.glsl>

mat4 model() {
    mat4 m = mat4(
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1
        );

    if (u_time > 28.) {
        float i = gl_InstanceIndex * 1024.213 + 2321.;
        m[3].x = noise(i + 0) * 64. - 32.;
        m[3].y = noise(i + 1) * 64. - 32.;
        m[3].z = noise(i + 2) * 64. - 32.;

        float x = noise(i * 123 + 0) + u_time * 0.5;
        float y = noise(i * 123 + 1) - u_time * 0.23;
        float z = noise(i * 123 + 2) + u_time * 0.11;
        m[0].xyz = vec3(
                cos(y) * cos(x),
                cos(y) * sin(x),
                -sin(y)
            );
        m[1].xyz = vec3(
                sin(z) * sin(y) * cos(x) - cos(z) * sin(x),
                sin(z) * sin(y) * sin(x) + cos(z) * cos(x),
                sin(z) * cos(y)
            );
        m[2].xyz = vec3(
                cos(z) * sin(y) * cos(x) + sin(z) * sin(x),
                cos(z) * sin(y) * sin(x) - sin(z) * cos(x),
                cos(z) * cos(y)
            );
    }

    return m;
}

void main() {
    out_color = in_color;
    vec4 clip_pos = u_view_projection * model() * vec4(in_position, 1.);
    gl_Position = clip_pos;
}
