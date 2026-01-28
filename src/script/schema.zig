const std = @import("std");

const camera = @import("camera.zig");

pub const ClipSegment = struct {
    t: f32,
    id: []const u8,
};

pub const CameraSegment = struct {
    t: f32,
    motion: []const camera.Motion,
    entry: ?camera.State = null,
    blend: f32 = 1,

    pub fn evaluate(
        self: CameraSegment,
        entry: *const camera.State,
        next: ?*const CameraSegment,
        next_entry: ?*const camera.State,
        time: f32,
        time_shift: f32,
        include_transients: bool,
    ) camera.State {
        const relative_time = time - self.t;
        var current_state = self.entry orelse entry.*;

        for (self.motion) |motion| {
            current_state = switch (motion) {
                inline else => |param, tag| blk: {
                    const func = @field(camera.fns, @tagName(tag));

                    const transient = hasParam(param, "transient") and
                        param.transient;
                    if (!include_transients and transient) continue;

                    const discontinuous = hasParam(param, "slip");
                    const slip = discontinuous and param.slip;

                    const t = if (transient)
                        time
                    else if (slip)
                        relative_time + time_shift
                    else if (discontinuous)
                        @max(0.0, relative_time)
                    else
                        relative_time;
                    break :blk func(t, current_state, param);
                },
            };
        }

        // Blend with next segment
        const next_seg = next orelse return current_state;
        const blend_start = next_seg.t - self.blend;

        if (self.blend > 0 and time >= blend_start) {
            const elapsed_in_blend = time - blend_start;
            const t = std.math.clamp(elapsed_in_blend / self.blend, 0.0, 1.0);
            const alpha = t * t * (3.0 - 2.0 * t);

            const target_entry = next_entry orelse &current_state;
            const next_state = next_seg.evaluate(
                target_entry,
                null,
                null,
                time,
                self.blend,
                include_transients,
            );
            current_state = current_state.lerp(next_state, alpha);
        }

        return current_state;
    }
};

pub const CameraEffect = struct {
    t: f32,
    duration: f32,
    motion: camera.Motion,
    fade_in: f32 = 1,
    fade_out: f32 = 1,
};

pub const Timeline = struct {
    clip_track: []const ClipSegment,
    camera_track: []const CameraSegment,
    camera_effects: []const CameraEffect,
};

inline fn hasParam(p: anytype, comptime name: []const u8) bool {
    const P = @TypeOf(p);
    return P != void and @hasField(P, name);
}

pub fn applyCameraEffects(
    effects: []const CameraEffect,
    base_state: camera.State,
    time: f32,
) camera.State {
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
                const func = @field(camera.fns, @tagName(tag));

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

pub fn ClipEnum(comptime timeline: Timeline) type {
    var fields: [timeline.clip_track.len]std.builtin.Type.EnumField = undefined;
    var num_fields = 0;
    outer: for (timeline.clip_track) |clip| {
        for (fields[0..num_fields]) |field| {
            if (std.mem.eql(u8, clip.id, field.name)) continue :outer;
        }
        fields[num_fields] = .{ .name = clip.id[0.. :0], .value = num_fields };
        num_fields += 1;
    }
    const bits = std.math.log2_int_ceil(usize, fields.len);
    return @Type(.{ .@"enum" = .{
        .tag_type = @Type(.{ .int = .{ .signedness = .unsigned, .bits = bits } }),
        .fields = fields[0..num_fields],
        .decls = &.{},
        .is_exhaustive = true,
    } });
}

pub fn clipTable(
    comptime timeline: Timeline,
) [timeline.clip_track.len]ClipEnum(timeline) {
    var clips: [timeline.clip_track.len]ClipEnum(timeline) = undefined;
    for (timeline.clip_track, &clips) |clip, *clip_enum| {
        clip_enum.* = @field(ClipEnum(timeline), clip.id);
    }
    return clips;
}

pub fn camEntryTable(
    comptime timeline: Timeline,
) [timeline.camera_track.len]camera.State {
    var entries: [timeline.camera_track.len]camera.State = undefined;
    entries[0] = .{
        .pos = .{ 0, 0, 1 },
        .target = .{ 0, 0, 0 },
    };

    for (1..timeline.camera_track.len) |i| {
        const next = timeline.camera_track[i];
        const prev = timeline.camera_track[i - 1];
        const prev_shift = if (i > 1) timeline.camera_track[i - 2].blend else 0;
        entries[i] = prev.evaluate(
            &entries[i - 1],
            null,
            null,
            next.t,
            prev_shift,
            false,
        );
    }

    return entries;
}
