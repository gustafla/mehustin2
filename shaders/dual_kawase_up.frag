#version 450

layout(location = 0) in vec2 in_uv;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_input_texture;

void main() {
    vec2 o = 0.5 / textureSize(u_input_texture, 0);

    vec4 color = vec4(0.0);

    color += texture(u_input_texture, in_uv + vec2(-o.x * 2.0, 0.0));
    color += texture(u_input_texture, in_uv + vec2(o.x * 2.0, 0.0));
    color += texture(u_input_texture, in_uv + vec2(0.0, -o.y * 2.0));
    color += texture(u_input_texture, in_uv + vec2(0.0, o.y * 2.0));

    color += texture(u_input_texture, in_uv + vec2(-o.x, o.y)) * 2.0;
    color += texture(u_input_texture, in_uv + vec2(o.x, o.y)) * 2.0;
    color += texture(u_input_texture, in_uv + vec2(-o.x, -o.y)) * 2.0;
    color += texture(u_input_texture, in_uv + vec2(o.x, -o.y)) * 2.0;

    out_color = color / 12.0;
}
