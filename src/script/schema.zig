const std = @import("std");

const script = @import("../script.zig");
const camera = @import("camera.zig");

pub const ClipSegment = struct {
    t: f32,
    id: []const u8,
};

pub const CameraControl = struct {
    t: f32,
    i: u32,
    position_lock: ?script.Anchor = null,
    target_lock: ?script.Anchor = null,
};

pub const Timeline = struct {
    clip_track: []const ClipSegment,
    camera: struct {
        control: []const CameraControl,
        tracks: []const []const camera.Segment,
        effects: []const camera.Effect,
    },
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

pub fn clipTable(
    comptime timeline: Timeline,
) [timeline.clip_track.len]ClipEnum(timeline) {
    var clips: [timeline.clip_track.len]ClipEnum(timeline) = undefined;
    for (timeline.clip_track, &clips) |clip, *clip_enum| {
        clip_enum.* = @field(ClipEnum(timeline), clip.id);
    }
    return clips;
}

pub fn maxLen(comptime slices: anytype) usize {
    var max = 0;
    for (slices) |slice| {
        if (slice.len > max) max = slice.len;
    }
    return max;
}

pub fn camEntryTable(
    comptime tracks: []const []const camera.Segment,
) [tracks.len][maxLen(tracks)]camera.State {
    var entries = std.mem.zeroes([tracks.len][maxLen(tracks)]camera.State);

    for (&entries, tracks) |*table, track| {
        table.*[0] = .{
            .pos = .{ 0, 0, 1 },
            .target = .{ 0, 0, 0 },
        };
        for (1..track.len) |i| {
            const next = track[i];
            const prev = track[i - 1];
            const prev_shift = if (i > 1) track[i - 2].blend else 0;
            table.*[i] = prev.evaluate(
                &table[i - 1],
                null,
                null,
                next.t,
                prev_shift,
            );
        }
    }

    return entries;
}
