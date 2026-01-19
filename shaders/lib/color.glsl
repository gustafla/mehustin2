vec3 acesApprox(vec3 v) {
    v *= 0.6;
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return clamp((v * (a * v + b)) / (v * (c * v + d) + e), 0., 1.);
}

float brightness(vec3 v) {
    return dot(v, vec3(0.2126, 0.7152, 0.0722));
}
