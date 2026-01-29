#version 450

layout(location = 0) in vec2 in_uv;

layout(location = 0) out vec4 out_color;

layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_time_g;
    float u_time;
    float u_time_r;
};

void main() {
    vec2 uv = vec2(in_uv.x + sin(in_uv.y * 4.45) * 3., in_uv.y + cos(in_uv.x * 2.1));
    uv.y += u_time + sin(uv.x + u_time * 2.1);
    uv.x += u_time * 0.8 + sin(uv.y + u_time * 1.1);
    uv.y *= 0.1;
    uv.y *= 0.2;
    float primary = sin(sin(uv.x * 4.) + sin(uv.y * 3. + u_time) + u_time);
    float pattern = max(sin(primary * primary) * 8. - 4., 0.);
    out_color = vec4(vec3(pattern), 1.);
}
