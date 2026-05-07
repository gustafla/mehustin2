const std = @import("std");

const config = @import("config");
const params = @import("params");

pub const kernel = struct {
    const size = getParam(.blur_radius);
    const sigma = getParam(.blur_sigma);

    pub fn gaussian() [size + 1]f32 {
        var buffer: [size + 1]f32 = undefined;

        for (0..buffer.len) |i| buffer[i] = g(@floatFromInt(i));
        normalize(&buffer);
        return buffer;
    }

    fn g(x: f32) f32 {
        return (1.0 / (sigma * @sqrt(2.0 * std.math.pi))) *
            (@exp((-1.0 / 2.0) * ((x * x) / (sigma * sigma))));
    }
};

fn getParam(comptime field: @EnumLiteral()) comptime_int {
    const name = @tagName(field);
    if (@hasDecl(params, name)) {
        return @field(params, name);
    }
    return @field(config, name);
}

fn normalize(xs: []f32) void {
    var sum: f32 = 0;
    for (xs) |x| sum += x;
    for (xs) |*x| x.* /= sum;
}
