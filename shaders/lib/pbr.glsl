#ifndef PBR_GLSL
#define PBR_GLSL

// Henyey-Greenstein phase function
// Determines how much light scatters towards the camera given the angle.
float phaseHenyeyGreenstein(float cos_theta, float g) {
    float num = 1.0 - g * g;
    float denom = 1.0 + g * g - 2.0 * g * cos_theta;
    return num / (4.0 * 3.14159 * pow(denom, 1.5));
}

// Schlick's approximation of the fresnel factor.
float fresnelSchlick(float cos_theta, float f0) {
    return f0 + (1. - f0) * pow(1.0 - cos_theta, 5.);
}

vec3 fresnelSchlick(float cos_theta, vec3 f0) {
    return f0 + (1. - f0) * pow(1.0 - cos_theta, 5.);
}

#endif
