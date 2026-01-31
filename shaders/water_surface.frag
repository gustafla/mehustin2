#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) flat in vec3 in_cam_pos;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(1.);
}
