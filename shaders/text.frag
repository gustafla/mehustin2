#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_font_atlas;

void main() {
    float sdf = texture(u_font_atlas, in_uv).r;
    if (sdf < 0.5) {
        discard;
    }
    out_color = in_color;
}
