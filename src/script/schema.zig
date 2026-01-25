const std = @import("std");

pub const Clip = struct {
    t: f32,
    id: []const u8,
};

pub const CameraSegment = struct {
    t: f32,
    id: []const u8,
    blend_time: f32 = 0,
};

pub const Timeline = struct {
    clip_track: []const Clip,
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
    const min_bits = std.math.log2_int_ceil(usize, fields.len);
    const bits = std.math.ceilPowerOfTwo(usize, min_bits) catch unreachable;
    return @Type(.{ .@"enum" = .{
        .tag_type = @Type(.{ .int = .{ .signedness = .unsigned, .bits = bits } }),
        .fields = fields[0..num_fields],
        .decls = &.{},
        .is_exhaustive = true,
    } });
}
