#ifndef COLOR_GLSL
#define COLOR_GLSL

// https://64.github.io/tonemapping/
vec3 acesApprox(vec3 v) {
    v *= 0.6;
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((v * (a * v + b)) / (v * (c * v + d) + e), 0., 1.);
}

vec3 reinhard(vec3 v) {
    return v / (1.0 + v);
}

float brightness(vec3 v) {
    return dot(v, vec3(0.2126, 0.7152, 0.0722));
}

#endif
