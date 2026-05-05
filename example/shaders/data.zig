const std = @import("std");

pub const kernel = struct {
    fn gaussian(x: f32, sigma: f32) f32 {
        return (1.0 / (sigma * @sqrt(2.0 * std.math.pi))) *
            (@exp((-1.0 / 2.0) * ((x * x) / (sigma * sigma))));
    }

    fn normalize(xs: []f32) void {
        var sum: f32 = 0;
        for (xs) |x| sum += x;
        for (xs) |*x| x.* /= sum;
    }

    pub fn gaussian101() [101]f32 {
        var buffer: [101]f32 = undefined;

        const sigma = 30;

        for (0..buffer.len) |i| {
            const x: f32 = @floatFromInt(i);
            buffer[i] = gaussian(x, sigma);
        }
        normalize(&buffer);
        return buffer;
    }

    pub fn gaussian17() [17]f32 {
        var buffer: [17]f32 = undefined;

        const sigma = 3;

        for (0..buffer.len) |i| {
            const x: f32 = @floatFromInt(i);
            buffer[i] = gaussian(x, sigma);
        }
        normalize(&buffer);
        return buffer;
    }
};
