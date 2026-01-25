pub const std = @import("std");

pub const CameraFn = fn (f32, CameraState) CameraState;

pub const CameraState = struct {
    pos: [3]f32,
    target: [3]f32,
    fov: f32 = 60,
    roll: f32 = 0,
};

pub fn camStayPut(t: f32, entry: CameraState) CameraState {
    _ = t;
    return entry;
}

pub fn camSinusoidalRotation(t: f32, entry: CameraState) CameraState {
    return .{
        .pos = entry.pos,
        .target = .{
            @sin((t - 14) / 4 * std.math.pi) * 3,
            @sin((t - 14) / 8 * std.math.pi) * 2,
            @cos(t / 3 * std.math.pi) * 4,
        },
        .fov = entry.fov,
        .roll = 0,
    };
}
