#version 450

layout(location = 0) in vec3 a_Position;
layout(location = 1) in vec3 a_Color;

layout(set = 1, binding = 0) uniform Matrices {
    mat4 u_Projection;
    mat4 u_View;
};

layout(location = 0) out vec3 Color;

void main() {
    vec4 pos = u_View * vec4(a_Position, 1.);
    Color = a_Color;
    gl_Position = u_Projection * pos;
}
