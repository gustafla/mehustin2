const std = @import("std");

const getParam = @import("genglsl").getParam;

// // Example: this generates a generated.glsl-file containing `kernel_gaussian`
// // as a static array.
// pub const kernel = struct {
//     const size = getParam("blur_radius");
//     const sigma: comptime_float = getParam("blur_sigma");
//
//     pub fn gaussian() [size + 1]f32 {
//         var buffer: [size + 1]f32 = undefined;
//
//         for (0..buffer.len) |i| buffer[i] = g(i);
//         return buffer;
//     }
//
//     fn g(x: anytype) f32 {
//         const x_f32: f32 = if (@TypeOf(x) == f32) x else @floatFromInt(x);
//         return (1.0 / (sigma * @sqrt(2.0 * std.math.pi))) *
//             (@exp((-1.0 / 2.0) * ((x_f32 * x_f32) / (sigma * sigma))));
//     }
// };
