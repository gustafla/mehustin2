// Rotates a vector 'v' by a unit quaternion 'q'
vec3 rotate_vector(vec3 v, vec4 q) {
    vec3 t = 2.0 * cross(q.xyz, v);
    return v + (q.w * t) + cross(q.xyz, t);
}
