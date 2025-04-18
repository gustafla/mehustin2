#version 450

layout(location = 0) in vec2 FragCoord;
layout(location = 0) out vec4 FragColor;

void main() {
    FragColor = vec4(FragCoord, 0., 1.);
}
