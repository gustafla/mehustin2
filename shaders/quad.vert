#version 450

layout(location = 0) out vec2 FragCoord;

void main() {
    vec2 c = vec2(-1, 1);
    vec4 coords[4] = vec4[4](c.xxyy, c.yxyy, c.xyyy, c.yyyy);
    FragCoord = coords[gl_VertexIndex].xy;
    gl_Position = coords[gl_VertexIndex];
}
