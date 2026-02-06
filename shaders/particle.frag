#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec3 in_pos;
layout(location = 2) flat in vec3 in_cam_pos;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = vec4(clamp(1.0 - length(in_uv - 0.5) * 2., 0.0, 1.0));
}
