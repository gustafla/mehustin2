const std = @import("std");
const math = @import("../math.zig");
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
};

pub const Segment = struct {
    t: f32,
    motion: []const Motion,
    entry: ?State = null,
    blend: f32 = 1,

    pub fn evaluate(
        self: Segment,
        entry: *const State,
        next: ?*const Segment,
        next_entry: ?*const State,
        time: f32,
        time_shift: f32,
    ) State {
        const relative_time = time - self.t;
        var current_state = self.entry orelse entry.*;

        for (self.motion) |motion| {
            current_state = switch (motion) {
                inline else => |param, tag| blk: {
                    const func = @field(fns, @tagName(tag));
                    const t = relative_time + time_shift;
                    break :blk func(t, current_state, param);
                },
            };
        }

        // Blend with next segment
        const blend_target = next orelse return current_state;
        const blend_target_entry = next_entry.?;
        const blend_start = blend_target.t - self.blend;

        if (self.blend > 0 and time >= blend_start) {
            const elapsed_in_blend = time - blend_start;
            const t = std.math.clamp(elapsed_in_blend / self.blend, 0.0, 1.0);
            const alpha = t * t * (3.0 - 2.0 * t);

            const next_state = blend_target.evaluate(
                blend_target_entry,
                null, // No "next next". Blend periods should not overlap.
                null,
                time,
                self.blend,
            );
            current_state = current_state.lerp(next_state, alpha);
        }

        return current_state;
    }
};

pub const Effect = struct {
    t: f32,
    duration: f32,
    motion: Motion,
    fade_in: f32 = 1,
    fade_out: f32 = 1,
};

pub fn evaluate(
    comptime track: []const Segment,
    comptime entries: []const State,
    cam_idx: usize,
    time: f32,
) State {
    const segment = track[cam_idx];
    const next: struct { segment: ?*const Segment, entry: ?*const State } =
        if (cam_idx + 1 < track.len)
            .{ .segment = &track[cam_idx + 1], .entry = &entries[cam_idx + 1] }
        else
            .{ .segment = null, .entry = null };

    // Time shift avoids negative interpolation on movements.
    // Otherwise the segment-relative time must be clamped non-negative,
    // so that the camera track doesn't make unexpected inverse movements
    // during blending, but then accelerations would look bad.
    const time_shift = if (cam_idx > 0) track[cam_idx - 1].blend else 0;

    return segment.evaluate(
        &entries[cam_idx],
        next.segment,
        next.entry,
        time,
        time_shift,
    );
}

pub fn applyEffects(
    effects: []const Effect,
    base_state: State,
    time: f32,
) State {
    var state = base_state;

    for (effects) |effect| {
        const start = effect.t;
        const end = start + effect.duration;

        if (time < start or time >= end) continue;

        const time_in = time - start;
        const time_left = end - time;

        var intensity: f32 = 1.0;
        if (effect.fade_in > 0 and time_in < effect.fade_in) {
            intensity = time_in / effect.fade_in;
        } else if (effect.fade_out > 0 and time_left < effect.fade_out) {
            intensity = time_left / effect.fade_out;
        }
        intensity = intensity * intensity * (3.0 - 2.0 * intensity);

        state = switch (effect.motion) {
            inline else => |param, tag| blk: {
                const func = @field(fns, @tagName(tag));

                var mod_param = param;
                if (hasParam(param, "mag")) mod_param.mag *= intensity; // shake
                if (hasParam(param, "amp")) mod_param.amp *= intensity; // wave, swivel
                if (hasParam(param, "angle")) mod_param.angle *= intensity; // bank
                if (hasParam(param, "roll")) mod_param.roll *= intensity; // shake roll

                break :blk func(time, state, mod_param);
            },
        };
    }

    return state;
}

inline fn hasParam(p: anytype, comptime name: []const u8) bool {
    const P = @TypeOf(p);
    return P != void and @hasField(P, name);
}

pub const fns = struct {
    pub fn move(
        t: f32,
        e: State,
        p: struct { axis: Vec3, speed: f32 = 1, pan: bool = false },
    ) State {
        const v = vec3.normalize(p.axis);
        const offset = v * @as(Vec3, @splat(t * p.speed));
        return .{
            .pos = e.pos + offset,
            .target = e.target + if (p.pan) offset else @as(Vec3, @splat(0)),
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn dolly(
        t: f32,
        e: State,
        p: struct { speed: f32 = 1 },
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
        p: struct { axis: Vec3, speed: f32 = 1 },
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
        p: struct { axis: Vec3, speed: f32 = 1 },
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
        p: struct { radius: f32 = 1, speed: f32 = 1, pan: bool = false },
    ) State {
        const fwd = vec3.normalize(e.target - e.pos);

        const world_up = if (@abs(fwd[1]) > 0.999) vec3.ZUP else vec3.YUP;
        const right = vec3.normalize(vec3.cross(fwd, world_up));
        const up = vec3.cross(right, fwd);

        const angle = t * p.speed;
        const c: Vec3 = @splat(std.math.cos(angle));
        const s: Vec3 = @splat(std.math.sin(angle));
        const r: Vec3 = @splat(p.radius);

        const offset = (right * c + up * s) * r;

        return .{
            .pos = e.pos + offset,
            .target = e.target + if (p.pan) offset else @as(Vec3, @splat(0)),
            .fov = e.fov,
            .roll = e.roll,
        };
    }

    pub fn swivel(
        t: f32,
        entry: State,
        param: struct { axis: Vec3, speed: f32 = 1, amp: f32 = 0 },
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
            freq: f32 = 1,
            amp: f32 = 1,
            phase: f32 = 0,
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
            fov: f32,
            speed: f32 = 1,
        },
    ) State {
        const ts = if (p.speed <= 0)
            1.0
        else
            std.math.clamp(t * p.speed, 0.0, 1.0);

        const ease = ts * ts * (3.0 - 2.0 * ts);

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

        const ease = ts * ts * (3.0 - 2.0 * ts);

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
