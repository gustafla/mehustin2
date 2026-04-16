#ifndef TRANSFORM_GLSL
#define TRANSFORM_GLSL

// Rotates a vector 'v' by a unit quaternion 'q'
vec3 rotateVector(vec3 v, vec4 q) {
    vec3 t = 2.0 * cross(q.xyz, v);
    return v + (q.w * t) + cross(q.xyz, t);
}

vec2 sphereUV(vec3 v) {
    const vec2 invAtan = vec2(0.1591, 0.3183);
    vec2 uv = vec2(atan(v.z, v.x), asin(v.y));
    uv *= invAtan;
    uv += 0.5;
    uv.y = 1. - uv.y; // Correct for stb_image
    return uv;
}

#endif
