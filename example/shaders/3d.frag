#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;

layout(location = 0) out vec4 out_color;

void main() {
    vec3 dir = normalize(-in_position);
    float lighting = max(dot(dir, in_normal), 0.0);
    vec3 color = abs(in_position) * 0.5;
    out_color = vec4(lighting * color, 1.0);
}
