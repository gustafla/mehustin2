#version 450

layout(location = 0) out vec4 out_color;

layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_time_g;
    float u_time;
    float u_time_r;
    float u_clip_length;
};

void main() {
    float t = u_time / u_clip_length;
    out_color = vec4(vec3(0.0), t);
}
