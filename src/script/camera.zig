pub const std = @import("std");

pub const Fn = fn (f32, State) State;

pub const State = struct {
    pos: [3]f32,
    target: [3]f32,
    fov: f32 = 60,
    roll: f32 = 0,
};

pub const fns = struct {
    pub fn stayPut(t: f32, entry: State) State {
        _ = t;
        return entry;
    }

    pub fn sinusoidalRotation(t: f32, entry: State) State {
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
};
