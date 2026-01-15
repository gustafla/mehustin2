#version 450

// TODO: uv and ndc
layout(location = 0) in vec2 FragCoord;

layout(location = 0) out vec4 FragColor;

layout(set = 3, binding = 0) uniform PushConstants {
    float u_Time;
};

#define EPSILON 0.001
#define PI 3.14159265
#define FOV 90.
#define RADIUS 10.

mat2 rotation(float a) {
    return mat2(
        cos(a), -sin(a),
        sin(a), cos(a)
    );
}
float sine(float x, float f, float t) {
    return cos(x * f + t) * 0.5 + 0.5;
}
float aspectRatio() {
    return float(WIDTH) / float(HEIGHT);
}
mat3 viewMatrix(vec3 target, vec3 origin) {
    vec3 f = normalize(target - origin);
    vec3 s = normalize(cross(f, vec3(0., 1., 0.)));
    vec3 u = cross(s, f);
    return mat3(s, u, f);
}
vec3 cameraRay() {
    float c = tan((90. - FOV / 2.) * (PI / 180.));
    return normalize(vec3(FragCoord * vec2(aspectRatio(), 1.), c));
}
float pattern(vec2 uv, float bias) {
    return clamp((cos(uv.x) * cos(uv.y) + bias) * 3., 0., 1.);
}
vec3 tex(vec2 uv, float t) {
    vec2 ref = uv * 2. - 1.;
    uv = uv * 3.;
    uv = rotation(sine(t, 0.12, 0.) * 2.) * uv;
    uv += vec2(sin(ref.y + t * 0.3), sin(ref.x * 0.5 + t * 0.2)) * 0.2;
    uv += vec2(sin(ref.y * 2.22 + t * 0.4), sin(ref.x * 1.11 + t * 0.4)) * 0.1;
    uv *= sine(t, 0.1, t * 0.2) * 50. + 140.;

    vec2 st = vec2(ref.x * aspectRatio(), ref.y) * 1.4;
    st += vec2(sin(ref.y * 0.6 + t * 0.7), sin(ref.x * 0.3 + t * 0.3)) * 0.6;
    st += vec2(sin(ref.y * 2.6 + t * 0.7), sin(ref.x * 4.3 + t * 0.3)) * sine(t, 0.75, 0.) * 2.3;
    float bias = cos(st.x + t) * 0.4 + sin(st.y - t * 0.3) * 0.4 + cos(st.y + t * 0.5) * 0.2;
    bias *= 4.14 * (sine(t, 0.03, 3.14) + 0.2);
    bias = sin(bias);

    vec3 pattern = vec3(pattern(uv, bias));

    vec3 bg = vec3(sin(t + ref.x) * 0.25 + 0.7, 0.5, 1.) * 1.1;
    return mix(bg, pattern, 0.13);
}
float tunnel(vec3 origin, vec3 direction) {
    float a = direction.x * direction.x + direction.y * direction.y;
    float b = 2.0 * (origin.x * direction.x + origin.y * direction.y);
    float c = origin.x * origin.x + origin.y * origin.y - RADIUS * RADIUS;
    float disc = b * b - 4.0 * a * c;
    float t = 0.0;
    if (disc < 0.0)
        return 1000000.0;
    else if (disc < EPSILON)
        return -b / (2.0 * a);
    else
        return min((-b + sqrt(disc)) / (2.0 * a), (-b - sqrt(disc)) / (2.0 * a));
}
float point_light(vec3 pos, vec3 light_pos, vec3 nml, float intensity) {
    float light_dist = distance(light_pos, pos);
    return max(dot(nml, -normalize(pos - light_pos)), 0.) * (intensity / (light_dist * light_dist));
}
vec3 aces_approx(vec3 v) {
    v *= 0.6f;
    float a = 2.51f;
    float b = 0.03f;
    float c = 2.43f;
    float d = 0.59f;
    float e = 0.14f;
    return clamp((v * (a * v + b)) / (v * (c * v + d) + e), 0.0f, 1.0f);
}
void main() {
    vec3 cam_pos = vec3(sin(u_Time * 0.2), sin(u_Time * 0.3), sin(u_Time * 0.4));
    vec3 cam_target = vec3(sin(u_Time * 0.54), sin(u_Time * 0.31), sin(u_Time * 0.14)) / 3. + vec3(0., 0., 3.);

    vec3 ray = viewMatrix(cam_target, cam_pos) * cameraRay();

    vec3 pos = cam_pos + ray * tunnel(cam_pos, ray);
    vec3 nml = normalize(vec3(vec2(0.), pos.z) - pos);
    vec2 uv = vec2(atan(pos.y, pos.x) + PI, pos.z / RADIUS) / (2. * PI);

    vec4 plights[3] = vec4[](
            vec4(sine(u_Time, 0.34, 0.) * RADIUS * 0.5, sine(u_Time, 0.49, 0.) * RADIUS * 0.5, -sine(u_Time, 0.13, 0.) * 80. - 20., 190.),
            vec4(sine(u_Time, 0.19, 0.) * RADIUS * 0.5, sine(u_Time, 0.44, 0.) * RADIUS * 0.5, -sine(u_Time, 0.21, 0.) * 100. - 20., 300.),
            vec4(sine(u_Time, 0.10, 0.) * RADIUS * 0.5, sine(u_Time, 0.53, 0.) * RADIUS * 0.5, -sine(u_Time, 0.54, 0.) * 45. - 20., 100.)
        );

    float light = 0.;
    float direct = 0.;
    for (int i = 0; i < 3; i++) {
        light += point_light(pos, plights[i].xyz, nml, plights[i].w);
        vec3 ltoc = cam_pos - plights[i].xyz;
        direct += clamp(
                (max(dot(ray, normalize(ltoc)), 0.) - (1. - 0.2 / pow(length(ltoc), 2.))) * float(1 << 18),
                0.,
                1.
            ) * plights[i].w;
    }

    vec3 albedo = tex(uv, u_Time) * sine(uv.x, 2. * PI, PI) + tex(vec2(mod(uv.x + 0.5, 1.), uv.y), u_Time) * sine(uv.x, 2. * PI, 0.);
    FragColor = vec4(aces_approx(light * albedo + direct), 1.);
}
