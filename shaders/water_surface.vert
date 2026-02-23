#version 450

layout(location = 0) in vec3 in_position;

layout(location = 0) out vec3 out_position;
layout(location = 1) out vec3 out_normal;
layout(location = 2) flat out vec3 out_cam_pos;

layout(std140, set = 1, binding = 0) uniform VertexFrameData {
    mat4 u_view_projection;
    vec4 u_cam_pos;
    vec4 u_cam_right;
    vec4 u_cam_up;
    float u_time;
};

void gerstnerWave(vec2 dir, float steepness, float wavelength, inout vec3 p, inout vec3 n) {
    float k = 2.0 * 3.14159 / wavelength;
    float c = sqrt(9.8 / k);
    vec2 d = normalize(dir);

    float f = k * (dot(d, p.xz) - c * u_time);
    float a = steepness / k;

    // Displacement
    p.x += d.x * (a * cos(f));
    p.y += a * sin(f);
    p.z += d.y * (a * cos(f));

    // Normal derivatives
    float wa = k * a;
    float s = sin(f);
    float co = cos(f);

    n.x -= d.x * (wa * s);
    n.y -= (wa * co);
    n.z -= d.y * (wa * s);
}

void main() {
    vec3 cam_pos = u_cam_pos.xyz;
    out_cam_pos = cam_pos;

    vec3 pos = in_position;
    vec3 normal = vec3(0, 1, 0);

    gerstnerWave(vec2(1.0, -0.5), 0.22, 66.6, pos, normal);
    gerstnerWave(vec2(0.5, -0.8), 0.1, 44.4, pos, normal);
    gerstnerWave(vec2(0.5, 0.5), 0.2, 33.3, pos, normal);
    gerstnerWave(vec2(-0.7, 1.3), 0.15, 16.6, pos, normal);

    out_position = pos - cam_pos; // Camera relative
    out_normal = normalize(normal);

    vec4 clip_pos = u_view_projection * vec4(pos, 1.);
    gl_Position = clip_pos;
}
