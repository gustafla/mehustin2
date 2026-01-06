#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_font_atlas;

void main() {
    float sdf = texture(u_font_atlas, in_uv).r;
    float alpha = smoothstep(0.0, 1.0, (sdf - 0.5) * 64.);
    float shadow = max((sdf - 0.25) * 2., 0.);
    shadow *= shadow;
    out_color = in_color * alpha;
    out_color.a = max(alpha, shadow);
}
