#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) flat in float in_alpha_fade;

layout(location = 0) out vec4 out_color;

void main() {
    float circle = length(in_uv * 2.0 - 1.0);
    float alpha = 1.0 - smoothstep(0.75, 1.0, circle);

    out_color = vec4(vec3(1.0), alpha * in_alpha_fade);
}
