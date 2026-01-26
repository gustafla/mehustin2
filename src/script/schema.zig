const std = @import("std");

const camera = @import("camera.zig");

pub const ClipSegment = struct {
    t: f32,
    id: []const u8,
};

pub const CameraSegment = struct {
    t: f32,
    id: []const u8,
    blend_time: f32 = 0,
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

pub fn camFnTable(comptime timeline: Timeline) []const *const camera.Fn {
    var fns: [timeline.camera_track.len]*const camera.Fn = undefined;
    for (timeline.camera_track, &fns) |cam, *fun| {
        fun.* = @field(camera.fns, cam.id);
    }
    return &fns;
}

pub fn camEntryTable(comptime timeline: Timeline) []const camera.State {
    var entries: [timeline.camera_track.len]camera.State = undefined;
    entries[0] = .{
        .pos = .{ 0, 0, 0 },
        .target = .{ 0, 0, -1 },
    };

    for (1..timeline.camera_track.len) |i| {
        const t = timeline.camera_track[i].t;
        const cam = timeline.camera_track[i - 1];
        const camFn = @field(camera.fns, cam.id);
        entries[i] = camFn(t - cam.t, entries[i - 1]);
    }

    return &entries;
}
