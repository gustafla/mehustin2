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
    pub fn lookAt(t: f32, entry: State) State {
        _ = t;
        return entry;
    }

    pub fn pan(
        t: f32,
        entry: State,
        param: struct { axis: Vec3, speed: f32 },
    ) State {
        const v = vec3.normalize(param.axis);
        const s: Vec3 = @splat(t * param.speed);
        const offset = v * s;
        return .{
            .pos = entry.pos + offset,
            .target = entry.target + offset,
            .fov = entry.fov,
            .roll = entry.roll,
        };
    }

    pub fn move(
        t: f32,
        entry: State,
        param: struct { axis: Vec3, speed: f32 },
    ) State {
        const v = vec3.normalize(param.axis);
        const s: Vec3 = @splat(t * param.speed);
        const offset = v * s;
        return .{
            .pos = entry.pos + offset,
            .target = entry.target,
            .fov = entry.fov,
            .roll = entry.roll,
        };
    }

    pub fn circle(
        t: f32,
        entry: State,
        param: struct { axis: Vec3, speed: f32 },
    ) State {
        const axis = vec3.normalize(param.axis);
        const rel_pos = entry.pos - entry.target;

        const height_val = vec3.dot(rel_pos, axis);
        const height_vec = axis * @as(Vec3, @splat(height_val));
        const radial_vec = rel_pos - height_vec;

        const rotated = vec3.rotatePerpendicular(radial_vec, axis, t * param.speed);

        return .{
            .pos = entry.target + height_vec + rotated,
            .target = entry.target,
            .fov = entry.fov,
            .roll = entry.roll,
        };
    }

    pub fn orbit(
        t: f32,
        entry: State,
        param: struct { axis: Vec3, speed: f32 },
    ) State {
        const rel_pos = entry.pos - entry.target;
        const view_dir = vec3.normalize(rel_pos);

        // Project axis onto the plane perpendicular to view direction
        const param_axis = vec3.normalize(param.axis);
        const proj_scalar = vec3.dot(param_axis, view_dir);
        const projection = view_dir * @as(Vec3, @splat(proj_scalar));

        var axis = param_axis - projection;

        // Fallback for when axis and view align
        if (vec3.lengthSq(axis) < 0.001) {
            axis = param_axis;
        } else {
            axis = vec3.normalize(axis);
        }

        const rotated = vec3.rotatePerpendicular(rel_pos, axis, t * param.speed);

        return .{
            .pos = entry.target + rotated,
            .target = entry.target,
            .fov = entry.fov,
            .roll = entry.roll,
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

        const ParamType = if (params.len == 3) params[2].type.? else void;
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
