#version 450

layout(location = 0) in vec3 Color;

layout(location = 0) out vec3 FragColor;

void main() {
    FragColor = Color;
}
