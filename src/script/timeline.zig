const std = @import("std");

const timeline: Timeline = @import("../timeline.zon");

const math = @import("../math.zig");
const vec3 = math.vec3;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const script = @import("../script.zig");
const Anchor = script.Anchor;
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
    blend: f32 = 0,
};

pub const Timeline = struct {
    clip_track: []const ClipSegment,
    camera: struct {
        control: []const CameraControl,
        tracks: []const []const camera.Segment,
        effects: []const camera.Effect,
    },
};

pub const State = struct {
    clip: script.Clip,
    clip_time: f32,
    clip_remaining_time: f32,
    camera: camera.State,
};

pub const Clip = blk: {
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
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = @Type(.{ .int = .{ .signedness = .unsigned, .bits = bits } }),
        .fields = fields[0..num_fields],
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

const clip_table = blk: {
    var clips: [timeline.clip_track.len]Clip = undefined;
    for (timeline.clip_track, &clips) |clip, *clip_enum| {
        clip_enum.* = @field(Clip, clip.id);
    }
    break :blk clips;
};

fn sumLen(comptime slices: anytype) usize {
    var sum = 0;
    for (slices) |slice| {
        sum += slice.len;
    }
    return sum;
}

const cam_entry_table = blk: {
    const tracks = timeline.camera.tracks;
    var offset_buf: [tracks.len + 1]usize = undefined;
    var entry_buf: [sumLen(tracks)]camera.State = undefined;
    var running_sum = 0;

    for (tracks, offset_buf[0..tracks.len]) |track, *offset| {
        const table = entry_buf[running_sum..][0..track.len];
        offset.* = running_sum;
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
        running_sum += track.len;
    }

    std.debug.assert(running_sum == entry_buf.len);
    offset_buf[tracks.len] = running_sum;

    const offset_table = offset_buf[0..].*;
    const entry_table = entry_buf[0..].*;

    break :blk struct {
        const offsets = offset_table;
        const entries = entry_table;

        pub fn getSlice(i: usize) []const camera.State {
            const start = offsets[i];
            const end = offsets[i + 1];
            return entries[start..end];
        }
    };
};

inline fn getAnchor(a: Anchor) Vec3 {
    return switch (a) {
        inline else => |tag| @field(script.anchor, @tagName(tag)),
    };
}

fn scan(slice: anytype, time: f32) usize {
    for (slice, 0..) |unit, i| {
        if (time < unit.t) {
            return i -| 1;
        }
    }

    return slice.len - 1;
}

pub fn resolve(time: f32) State {
    const clip_idx = scan(timeline.clip_track, time);
    const clip = clip_table[clip_idx];
    const clip_time = time - timeline.clip_track[clip_idx].t;
    const clip_remaining_time = if (clip_idx + 1 < timeline.clip_track.len)
        timeline.clip_track[clip_idx + 1].t - time
    else
        std.math.inf(f32);

    const cam_control_idx = scan(timeline.camera.control, time);
    const cam_control = timeline.camera.control[cam_control_idx];
    const cam_track = timeline.camera.tracks[cam_control.i];
    const cam_idx = scan(cam_track, time);
    var cam_state = camera.evaluate(
        cam_track,
        cam_entry_table.getSlice(cam_control.i),
        cam_idx,
        time,
    );

    var blend_alpha: f32 = 0.0;
    const next_control_idx = cam_control_idx + 1;

    // Check if we are transitioning to the next control segment
    if (next_control_idx < timeline.camera.control.len) {
        const next_ctrl = timeline.camera.control[next_control_idx];
        const blend_start = next_ctrl.t - cam_control.blend;

        if (cam_control.blend > 0 and time >= blend_start) {
            const t = std.math.clamp(
                (time - blend_start) / cam_control.blend,
                0.0,
                1.0,
            );
            blend_alpha = t * t * (3.0 - 2.0 * t);
        }
    }

    // Resolve position lock
    var pos_offset = if (cam_control.position_lock) |to|
        getAnchor(to)
    else
        @as(Vec3, @splat(0));

    if (blend_alpha > 0) {
        const next_ctrl = timeline.camera.control[next_control_idx];
        const next_offset = if (next_ctrl.position_lock) |to|
            getAnchor(to)
        else
            @as(Vec3, @splat(0));
        pos_offset = vec3.lerp(pos_offset, next_offset, blend_alpha);
    }

    // Apply rig offset to state
    cam_state.pos += pos_offset;
    const track_target_world = cam_state.target + pos_offset;

    // Resolve target lock
    var look_target = if (cam_control.target_lock) |to|
        getAnchor(to)
    else
        track_target_world;

    if (blend_alpha > 0) {
        const next_ctrl = timeline.camera.control[next_control_idx];
        const next_look = if (next_ctrl.target_lock) |to|
            getAnchor(to)
        else
            track_target_world;
        look_target = vec3.lerp(look_target, next_look, blend_alpha);
    }

    cam_state.target = look_target;

    // Finally, apply effects
    const cam = camera.applyEffects(timeline.camera.effects, cam_state, time);

    return .{
        .clip = clip,
        .clip_time = clip_time,
        .clip_remaining_time = clip_remaining_time,
        .camera = cam,
    };
}
