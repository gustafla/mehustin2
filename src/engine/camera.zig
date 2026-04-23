const std = @import("std");

const math = @import("math.zig");
const vec3 = math.vec3;
const Vec3 = math.Vec3;

pub const State = struct {
    pos: Vec3,
    target: Vec3 = @splat(0),
    fov: f32 = 60,
    roll: f32 = 0,

    pub fn lerp(a: State, b: State, t: f32) State {
        return .{
            .pos = vec3.lerp(a.pos, b.pos, t),
            .target = vec3.lerp(a.target, b.target, t),
            .fov = std.math.lerp(a.fov, b.fov, t),
            .roll = std.math.lerp(a.roll, b.roll, t),
        };
    }

    pub fn getBasis(self: State) struct { right: Vec3, up: Vec3, fwd: Vec3 } {
        const fwd = vec3.normalize(self.target - self.pos);
        const world_up = if (@abs(fwd[1]) > 0.999) vec3.ZUP else vec3.YUP;
        const right = vec3.normalize(vec3.cross(fwd, world_up));
        const up = vec3.cross(right, fwd);
        return .{ .right = right, .up = up, .fwd = fwd };
    }
};

pub const LocalAxis = enum { lateral, vertical, longitudinal };

pub const fns = struct {
    pub fn move(
        t: f32,
        e: State,
        p: struct {
            axis: Vec3,
            speed: f32 = 1,
            strafe: bool = false,
        },
    ) State {
        const v = vec3.normalize(p.axis);
        const offset = v * @as(Vec3, @splat(t * p.speed));
        return .{
            .pos = e.pos + offset,
            .target = e.target + if (p.strafe) offset else @as(Vec3, @splat(0)),
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn dolly(
        t: f32,
        e: State,
        p: struct {
            speed: f32 = 1,
        },
    ) State {
        const v = vec3.normalize(e.target - e.pos);
        const offset = v * @as(Vec3, @splat(t * p.speed));
        return .{
            .pos = e.pos + offset,
            .target = e.target + offset,
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn circle(
        t: f32,
        e: State,
        p: struct {
            axis: Vec3,
            speed: f32 = 1,
        },
    ) State {
        const axis = vec3.normalize(p.axis);
        const rel_pos = e.pos - e.target;
        const rotated = vec3.rotate(rel_pos, axis, t * p.speed);

        return .{
            .pos = e.target + rotated,
            .target = e.target,
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn orbit(
        t: f32,
        e: State,
        p: struct {
            axis: Vec3,
            speed: f32 = 1,
        },
    ) State {
        const rel_pos = e.pos - e.target;
        const view_dir = vec3.normalize(rel_pos);
        const param_axis = vec3.normalize(p.axis);

        // Remove the part of the axis that points towards the camera
        const proj = view_dir * @as(Vec3, @splat(vec3.dot(param_axis, view_dir)));
        var axis = param_axis - proj;

        // Fallback: If axis aligns with view, use original axis
        if (vec3.lengthSq(axis) < 0.001) {
            axis = param_axis;
        } else {
            axis = vec3.normalize(axis);
        }

        const rotated = vec3.rotate(rel_pos, axis, t * p.speed);

        return .{
            .pos = e.target + rotated,
            .target = e.target,
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn spiral(
        t: f32,
        e: State,
        p: struct {
            radius: f32 = 1,
            speed: f32 = 1,
            strafe: bool = false,
        },
    ) State {
        const basis = e.getBasis();

        const angle = t * p.speed;
        const c: Vec3 = @splat(std.math.cos(angle));
        const s: Vec3 = @splat(std.math.sin(angle));
        const r: Vec3 = @splat(p.radius);

        const offset = (basis.right * c + basis.up * s) * r;

        return .{
            .pos = e.pos + offset,
            .target = e.target + if (p.strafe) offset else @as(Vec3, @splat(0)),
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn swivel(
        t: f32,
        e: State,
        p: struct {
            axis: ?Vec3 = null,
            local: LocalAxis = .vertical,
            speed: f32 = 1,
            amp: f32 = 0,
        },
    ) State {
        const basis = e.getBasis();
        const axis = if (p.axis) |a| vec3.normalize(a) else blk: {
            break :blk switch (p.local) {
                .vertical => basis.up,
                .lateral => basis.right,
                .longitudinal => basis.fwd,
            };
        };

        const angle = if (p.amp > 0)
            std.math.sin(t * p.speed) * p.amp
        else
            t * p.speed;

        const new_forward = vec3.rotate(basis.fwd, axis, angle);

        return .{
            .pos = e.pos,
            .target = e.pos + new_forward,
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn shake(
        t: f32,
        e: State,
        p: struct {
            freq: f32 = 1.0,
            amp: f32 = 0.1,
            seed: f32 = 0.0,
            roll: f32 = 0.0,
            local: ?LocalAxis = null,
        },
    ) State {
        const s = p.seed;

        const n1 = std.math.sin(t * p.freq + s) + std.math.sin(t * p.freq * 0.5 + s + 1.0);
        const n2 = std.math.sin(t * p.freq * 1.3 + s + 2.0) * 0.7;
        const n3 = std.math.cos(t * p.freq * 0.8 + s + 3.0);

        const offset = if (p.local) |axis| blk: {
            const basis = e.getBasis();
            const dir = switch (axis) {
                .lateral => basis.right,
                .vertical => basis.up,
                .longitudinal => basis.fwd,
            };
            break :blk dir * @as(Vec3, @splat(n1 * p.amp));
        } else @as(Vec3, .{ n1, n2, n3 }) * @as(Vec3, @splat(p.amp));

        return .{
            .pos = e.pos + offset,
            .target = e.target + offset,
            .fov = e.fov,
            .roll = e.roll + (offset[0] * p.roll),
        };
    }

    pub fn wave(
        t: f32,
        e: State,
        p: struct {
            axis: ?Vec3 = null,
            local: LocalAxis = .vertical,
            freq: f32 = 1,
            amp: f32 = 1,
            phase: f32 = 0,
            strafe: bool = false,
        },
    ) State {
        const axis = if (p.axis) |a| vec3.normalize(a) else blk: {
            const basis = e.getBasis();
            break :blk switch (p.local) {
                .lateral => basis.right,
                .vertical => basis.up,
                .longitudinal => basis.fwd,
            };
        };

        const s = std.math.sin((t * p.freq) + p.phase) * p.amp;
        const offset = axis * @as(Vec3, @splat(s));

        return .{
            .pos = e.pos + offset,
            .target = e.target + if (p.strafe) offset else @as(Vec3, @splat(0)),
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn zoom(
        t: f32,
        e: State,
        p: struct {
            fov: f32,
            speed: f32 = 1,
        },
    ) State {
        const ts = if (p.speed <= 0)
            1.0
        else
            std.math.clamp(t * p.speed, 0.0, 1.0);

        const ease = math.smoothstep(ts);

        return .{
            .pos = e.pos,
            .target = e.target,
            .fov = std.math.clamp(e.fov + (p.fov * ease), 1, 179),
            .roll = e.roll,
        };
    }

    pub fn bank(
        t: f32,
        e: State,
        p: struct {
            angle: f32,
            speed: f32 = 1,
        },
    ) State {
        const ts = if (p.speed <= 0)
            1.0
        else
            std.math.clamp(t * p.speed, 0.0, 1.0);

        const ease = math.smoothstep(ts);

        return .{
            .pos = e.pos,
            .target = e.target,
            .fov = e.fov,
            .roll = e.roll + (p.angle * ease),
        };
    }
};

pub const Motion = blk: {
    const decls = @typeInfo(fns).@"struct".decls;
    const Enum = std.meta.DeclEnum(fns);
    var field_names: [decls.len][]const u8 = undefined;
    var field_types: [decls.len]type = undefined;

    for (decls, 0..) |decl, i| {
        const func = @field(fns, decl.name);
        const params = @typeInfo(@TypeOf(func)).@"fn".params;

        const ParamType = params[2].type.?;
        field_names[i] = decl.name;
        field_types[i] = ParamType;
    }

    break :blk @Union(.auto, Enum, &field_names, &field_types, &@splat(.{}));
};
