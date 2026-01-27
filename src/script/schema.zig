const std = @import("std");

const camera = @import("camera.zig");

pub const ClipSegment = struct {
    t: f32,
    id: []const u8,
};

pub const CameraSegment = struct {
    t: f32,
    cam: camera.Motion,
    entry: ?camera.State = null,
    blend: f32 = 0,

    pub fn evaluate(
        self: CameraSegment,
        next: ?*const CameraSegment,
        default_entry: camera.State,
        time: f32,
    ) camera.State {
        const relative_time = time - self.t;
        const entry = if (self.entry) |entry| entry else default_entry;

        const state_current = switch (self.cam) {
            inline else => |param, tag| blk: {
                const func = @field(camera.fns, @tagName(tag));
                if (@TypeOf(param) == void) {
                    break :blk func(relative_time, entry);
                } else {
                    break :blk func(relative_time, entry, param);
                }
            },
        };

        if (next) |next_seg| {
            const blend_start = next_seg.t - self.blend;

            if (self.blend > 0 and time >= blend_start) {
                const elapsed_in_blend = time - blend_start;
                const linear_t = std.math.clamp(elapsed_in_blend / self.blend, 0.0, 1.0);
                // Hermite interpolation
                const alpha = linear_t * linear_t * (3.0 - 2.0 * linear_t);
                const state_next = next_seg.evaluate(null, state_current, next_seg.t);
                return state_current.lerp(state_next, alpha);
            }
        }

        return state_current;
    }
};

pub const Timeline = struct {
    clip_track: []const ClipSegment,
    camera_track: []const CameraSegment,
};

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

pub fn clipTable(comptime timeline: Timeline) []const ClipEnum(timeline) {
    var clips: [timeline.clip_track.len]ClipEnum(timeline) = undefined;
    for (timeline.clip_track, &clips) |clip, *clip_enum| {
        clip_enum.* = @field(ClipEnum(timeline), clip.id);
    }
    return &clips;
}

pub fn camEntryTable(comptime timeline: Timeline) []const camera.State {
    var entries: [timeline.camera_track.len]camera.State = undefined;
    entries[0] = .{
        .pos = .{ 0, 0, 1 },
        .target = .{ 0, 0, 0 },
    };

    for (1..timeline.camera_track.len) |i| {
        const next = timeline.camera_track[i];
        const prev = timeline.camera_track[i - 1];
        entries[i] = prev.evaluate(&next, entries[i - 1], next.t);
    }

    return &entries;
}
