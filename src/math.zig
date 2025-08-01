const std = @import("std");

pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    const ZERO = std.mem.zeroes(Vec3);
    const YUP = std.mem.zeroInit(Vec3, .{ .y = 1 });
};

pub const Mat4 = extern struct {
    col: [4][4]f32,

    fn perspective(fov: f32, aspect: f32, near: f32, far: f32) Mat4 {
        _ = fov;
        _ = aspect;
        _ = near;
        _ = far;
        const col = std.mem.zeroes([4][4]f32);

        return .{ .col = col };
    }
};
