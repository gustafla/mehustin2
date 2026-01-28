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
                    const P = @TypeOf(param);

                    const transient = P != void and
                        @hasField(P, "transient") and
                        param.transient;
                    if (!include_transients and transient) continue;

                    const discontinuous = P != void and @hasField(P, "slip");
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
