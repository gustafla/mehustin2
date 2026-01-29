#version 450

// TODO: uv and ndc
layout(location = 0) in vec2 FragCoord;

layout(location = 0) out vec4 FragColor;

layout(std140, set = 3, binding = 0) uniform FragmentFrameData {
    float u_time_g;
    float u_time;
    float u_time_r;
};

#define EPSILON 0.0001
#define ITERATIONS 64
#define MAX_DIST 8.
#define PI 3.14159265
#define FOV 65.

#define RI_VACUUM 1.
#define RI_DIAMOND 2.417

mat3 roll(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat3(
        1.0, 0.0, 0.0,
        0.0, c, -s,
        0.0, s, c
    );
}

mat3 pitch(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat3(
        c, 0.0, s,
        0.0, 1.0, 0.0,
        -s, 0.0, c
    );
}

mat3 yaw(float angle) {
    float c = cos(angle);
    float s = sin(angle);
    return mat3(
        c, -s, 0.0,
        s, c, 0.0,
        0.0, 0.0, 1.0
    );
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

vec3 cameraRay(vec2 uv) {
    float c = tan((90. - FOV / 2.) * (PI / 180.));
    return normalize(vec3(uv * vec2(aspectRatio(), 1.), c));
}

float opUnion(float d1, float d2) {
    return min(d1, d2);
}

float opSubtraction(float d1, float d2) {
    return max(-d1, d2);
}

float opIntersection(float d1, float d2) {
    return max(d1, d2);
}

float sdCone(vec3 p, vec2 c, float h) {
    float q = length(p.xz);
    return max(dot(c.xy, vec2(q, p.y)), -h - p.y);
}

float sdOctahedron(vec3 p, float s) {
    p = abs(p);
    return (p.x + p.y + p.z - s) * 0.57735027;
}

float sdf(vec3 pos) {
    float o1 = sdOctahedron(pos, 1.);
    float o2 = sdOctahedron(pitch(u_time * 0.33) * pos, 1.);
    float o3 = sdOctahedron(yaw(u_time * 0.2342134) * pos, 1.);
    float o4 = sdOctahedron(roll(u_time * 0.434) * pos, 1.);
    return opUnion(o1, opUnion(o2, opUnion(o3, o4)));
}

vec3 normal(vec3 p) {
    return normalize(vec3(
            sdf(vec3(p.x + EPSILON, p.y, p.z)) - sdf(vec3(p.x - EPSILON, p.y, p.z)),
            sdf(vec3(p.x, p.y + EPSILON, p.z)) - sdf(vec3(p.x, p.y - EPSILON, p.z)),
            sdf(vec3(p.x, p.y, p.z + EPSILON)) - sdf(vec3(p.x, p.y, p.z - EPSILON))
        ));
}

float march(vec3 o, vec3 d, float side) {
    float t = 0.1;
    float dist = 0.;
    for (int i = 0; i < ITERATIONS; i++) {
        dist = sdf(o + d * t) * side;
        t += dist;
        if (dist < EPSILON) {
            break;
        }
        if (t > MAX_DIST) {
            break;
        }
    }
    return t;
}

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1. - F0) * pow(1.0 - cosTheta, 5.);
}

vec3 attenuation(float t, vec3 color) {
    vec3 a = (1. - color) * 0.15 * -t;
    return exp(a);
}

vec3 palette(float t, vec3 a, vec3 b, vec3 c, vec3 d) {
    return a + b * cos(6.283185 * (c * t + d));
}

vec3 environment(vec3 dir) {
    float x = atan(dir.z, dir.x) + PI;
    vec2 uv = vec2(x, dir.y * 0.5 + 0.5);

    vec3 a = vec3(0.5);
    vec3 b = vec3(0.5);
    vec3 c = vec3(1., 0.7, 0.4);
    vec3 d = vec3(0., 0.15, 0.2);
    vec3 col = palette(uv.x, a, b, c, d);
    float cosy = cos(uv.y * 15.) * 0.5 + 0.5;
    float cosx = cos(uv.x + PI) * 0.5 + 0.5;
    return vec3(col * cosy * cosx) * 4.;
}

vec3 acesApprox(vec3 v) {
    v *= 0.6;
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((v * (a * v + b)) / (v * (c * v + d) + e), 0., 1.);
}

vec3 shade(vec3 origin, vec3 dir) {
    // March primary ray
    float t = march(origin, dir, 1.);

    // Handle misses
    if (t > MAX_DIST) {
        return environment(dir);
    }

    // Position and normal
    vec3 hitPos = origin + dir * t;
    vec3 hitNormal = normal(hitPos);

    // Reflectance
    float n_minus1 = RI_DIAMOND - 1.;
    float n_plus1 = RI_DIAMOND + 1.;
    float r0 = (n_minus1 * n_minus1) / (n_plus1 * n_plus1);
    vec3 fresnel = fresnelSchlick(dot(dir, -hitNormal), vec3(r0));
    vec3 reflected = environment(reflect(dir, hitNormal)) * fresnel;

    // Refraction
    dir = refract(dir, hitNormal, RI_VACUUM / RI_DIAMOND);
    t = march(hitPos, dir, -1.);
    hitPos = hitPos + dir * t;
    hitNormal = -normal(hitPos);
    vec3 dir2 = refract(dir, hitNormal, RI_DIAMOND / RI_VACUUM);
    // Hack for when refract returns 0
    dir2 += step(-EPSILON, -dot(dir2, dir2)) * dir;

    return environment(dir2) * attenuation(t * 16., vec3(0.3)) + reflected;
}

void main() {
    // From -1 to 1
    vec2 uv = FragCoord;

    // Camera parameters
    vec3 origin = vec3(sin(u_time) * 3., cos(u_time), cos(u_time) * 3.);
    vec3 lookAt = vec3(0.);

    // Direction to scene
    vec3 dir = viewMatrix(lookAt, origin) * cameraRay(uv);

    // Render
    vec3 color = shade(origin, dir);

    // Output to screen
    // https://64.github.io/tonemapping/
    FragColor = vec4(acesApprox(color), 1.0);
}
