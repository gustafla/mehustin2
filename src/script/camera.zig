const std = @import("std");
const math = @import("../math.zig");
const vec3 = math.vec3;
const Vec3 = math.Vec3;

pub const Fn = fn (f32, State) State;

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
};

pub const fns = struct {
    pub fn hold(
        t: f32,
        e: State,
        p: void,
    ) State {
        _ = t;
        _ = p;
        return e;
    }

    pub fn pan(
        t: f32,
        e: State,
        p: struct { axis: Vec3, speed: f32, slip: bool = true },
    ) State {
        const v = vec3.normalize(p.axis);
        const offset = v * @as(Vec3, @splat(t * p.speed));
        return .{
            .pos = e.pos + offset,
            .target = e.target + offset,
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn move(
        t: f32,
        e: State,
        p: struct { axis: Vec3, speed: f32, slip: bool = true },
    ) State {
        const v = vec3.normalize(p.axis);
        const offset = v * @as(Vec3, @splat(t * p.speed));
        return .{
            .pos = e.pos + offset,
            .target = e.target,
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn dolly(
        t: f32,
        e: State,
        p: struct { speed: f32, slip: bool = true },
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
        p: struct { axis: Vec3, speed: f32 },
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
        p: struct { axis: Vec3, speed: f32 },
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

    pub fn swivel(
        t: f32,
        entry: State,
        param: struct { axis: Vec3, speed: f32, amp: f32 = 0 },
    ) State {
        const forward = entry.target - entry.pos;
        const axis_norm = vec3.normalize(param.axis);

        const angle = if (param.amp > 0)
            std.math.sin(t * param.speed) * param.amp
        else
            t * param.speed;

        const new_forward = vec3.rotate(forward, axis_norm, angle);

        return .{
            .pos = entry.pos,
            .target = entry.pos + new_forward,
            .fov = entry.fov,
            .roll = entry.roll,
        };
    }

    pub fn shake(
        t: f32,
        e: State,
        p: struct {
            freq: f32 = 1.0,
            mag: f32 = 0.1,
            seed: f32 = 0.0,
            roll: f32 = 0.0,
            transient: bool = true,
        },
    ) State {
        const s = p.seed;

        const noise_vec = Vec3{
            std.math.sin(t * p.freq + s) + std.math.sin(t * p.freq * 0.5 + s + 1.0),
            std.math.sin(t * p.freq * 1.3 + s + 2.0) * 0.7,
            std.math.cos(t * p.freq * 0.8 + s + 3.0),
        };

        const offset = noise_vec * @as(Vec3, @splat(p.mag));

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
            axis: Vec3,
            freq: f32,
            amp: f32,
            phase: f32 = 0,
            transient: bool = true,
        },
    ) State {
        const s = std.math.sin((t * p.freq) + p.phase) * p.amp;
        const offset = vec3.normalize(p.axis) * @as(Vec3, @splat(s));

        return .{
            .pos = e.pos + offset,
            .target = e.target,
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn zoom(
        t: f32,
        e: State,
        p: struct {
            speed: f32,
            min: f32 = 0.1,
            max: f32 = 179.9,
            slip: bool = true,
        },
    ) State {
        return .{
            .pos = e.pos,
            .target = e.target,
            .fov = std.math.clamp(e.fov + (t * p.speed), p.min, p.max),
            .roll = e.roll,
        };
    }

    pub fn bank(
        t: f32,
        e: State,
        p: struct {
            angle: f32,
            speed: f32 = 0,
            slip: bool = true,
        },
    ) State {
        const fraction = if (p.speed <= 0)
            1.0
        else
            std.math.clamp(t * p.speed, 0.0, 1.0);

        const ease = fraction * fraction * (3.0 - 2.0 * fraction);

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
    var union_fields: [decls.len]std.builtin.Type.UnionField = undefined;

    for (decls, &union_fields) |decl, *field| {
        const func = @field(fns, decl.name);
        const params = @typeInfo(@TypeOf(func)).@"fn".params;

        const ParamType = params[2].type.?;
        field.* = .{
            .name = decl.name,
            .type = ParamType,
            .alignment = @alignOf(ParamType),
        };
    }

    break :blk @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = Enum,
        .fields = &union_fields,
        .decls = &.{},
    } });
};
