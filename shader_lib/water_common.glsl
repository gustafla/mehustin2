#ifndef WATER_COMMON_GLSL
#define WATER_COMMON_GLSL

#include <pbr.glsl>

#ifndef SUN_COLOR
#define SUN_COLOR (vec3(1, 0.9, 0.8) * brightness)
#endif

#ifndef SKY_COLOR
#define SKY_COLOR (sky_color.rgb * brightness * 3)
#endif

const float water_ior = 1.333;
const vec3 k_sigma_a = vec3(0.19, 0.04, 0.03) * 0.1;
const vec3 k_sigma_s = vec3(0.02, 0.023, 0.03) * 0.1;
const vec3 k_sigma_t = k_sigma_a + k_sigma_s;
const float k_g = 0.7;

vec3 integrateScattering(vec3 radiance, vec3 ext_sun, vec3 ext_view, float dist) {
    vec3 extinction = ext_sun + ext_view;
    vec3 result = (1.0 - exp(-extinction * dist)) / extinction;
    return radiance * result;
}

vec3 underwaterScattering(
    vec3 ro,
    vec3 rd,
    float dist,
    vec3 sun_dir
) {
    // If waves move vertices above y=0, we must clamp depth to 0
    // to prevent exploding exponential light values.
    float depth = max(-ro.y, 0.0);

    // Refract sun dir
    vec3 refracted_sun = normalize(vec3(sun_dir.x, sun_dir.y * water_ior, sun_dir.z));

    // Phase function
    float cos_theta = dot(rd, refracted_sun);
    float phase = phaseHenyeyGreenstein(cos_theta, k_g);

    // Radiance at start point
    float dist_sun_to_camera = depth / refracted_sun.y;
    vec3 sun_at_camera = SUN_COLOR * exp(-k_sigma_t * dist_sun_to_camera);

    // Integrate
    // If looking down (rd.y < 0), we move deeper -> path to sun gets longer
    // If looking up (rd.y > 0), we move shallower -> path to sun gets shorter
    float gradient = -rd.y; // + when going down, - when going up
    float sun_gradient = gradient / refracted_sun.y;

    // Scattering term
    vec3 sunlight = integrateScattering(
            sun_at_camera * phase,
            k_sigma_t * sun_gradient,
            k_sigma_t,
            dist
        ) * k_sigma_s;

    // Ambient term
    // Geometric scale is just vertical gradient
    vec3 skylight = integrateScattering(
            SKY_COLOR * exp(-k_sigma_t * depth) * (1.0 / 3.14),
            k_sigma_t * gradient,
            k_sigma_t,
            dist
        ) * k_sigma_s;

    return sunlight + skylight;
}

vec3 underwaterFog(
    vec3 color,
    float dist,
    vec3 ro,
    vec3 rd,
    vec3 sun_dir
) {
    float dist_surface = 1e9;

    if (rd.y > 0.001) {
        dist_surface = max(-ro.y, 0.0) / rd.y;
    }

    float effective_dist = min(dist, dist_surface);

    vec3 volume_light = underwaterScattering(ro, rd, effective_dist, sun_dir);
    vec3 transmission = exp(-k_sigma_t * dist);

    return volume_light + (color * transmission);
}

#endif
