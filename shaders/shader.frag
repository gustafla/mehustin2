#version 450

layout(location = 0) in vec2 FragCoord;
layout(location = 0) out vec4 FragColor;

layout(set = 3, binding = 0) uniform PushConstants {
    vec2 u_Resolution;
    float u_Time;
};

void main() {
    FragColor = vec4(vec3(0.4), 1.);

    if (u_Time > 55.) {
        vec2 uv = vec2(FragCoord.x + sin(FragCoord.y * 4.45) * 3., FragCoord.y + cos(FragCoord.x * 2.1));
        uv.y += u_Time + sin(uv.x + u_Time * 2.1);
        uv.x += u_Time * 0.8 + sin(uv.y + u_Time * 1.1);
        uv.y *= 0.1;
        uv.y *= 0.2;
        float primary = sin(sin(uv.x * 4.) + sin(uv.y * 3. + u_Time) + u_Time);
        float pattern = max(sin(primary * primary) * 8. - 4., 0.);
        FragColor = vec4(vec3(pattern), 1.);
    }
}
