#version 450

layout(location = 0) in vec2 in_uv;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_input_texture;

#define SAMPLE_SCALE 1.0
#define SAMPLE_WEIGHT 1.0

void main() {
    vec2 halfpixel = vec2(0.5) / vec2(WIDTH, HEIGHT);
    vec2 o = halfpixel * SAMPLE_SCALE;

    vec4 color = texture(u_input_texture, in_uv) * 4.0;
    color += texture(u_input_texture, in_uv + vec2(-o.x, -o.y));
    color += texture(u_input_texture, in_uv + vec2(o.x, -o.y));
    color += texture(u_input_texture, in_uv + vec2(-o.x, o.y));
    color += texture(u_input_texture, in_uv + vec2(o.x, o.y));

    out_color = (color / 8.0) * SAMPLE_WEIGHT;
}
