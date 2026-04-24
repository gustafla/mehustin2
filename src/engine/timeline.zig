const std = @import("std");

const script = @import("script");
const Anchor = script.Anchor;
const timeline = script.config.timeline;

const camera = @import("camera.zig");
const math = @import("math.zig");
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const schema = @import("schema.zig");
const EventTime = schema.Timeline.EventTime;
const Text = schema.Timeline.Text;
const Camera = schema.Timeline.Camera;
const Font = schema.Font;
const types = @import("types.zig");
const BufferInfo = types.BufferInfo;
const TextureInfo = types.TextureInfo;
const util = @import("util.zig");

pub const bps = if (@hasField(@TypeOf(script.config.main), "bpm"))
    @as(comptime_float, script.config.main.bpm) / 60.0
else
    1.0;
pub const spb = 1.0 / bps;

pub const duration = blk: {
    var last = 0.0;
    for (timeline.tags, tag_time_table) |tag_raw, tag_t| {
        last = @max(last, tag_t + tag_raw.duration);
    }
    break :blk last * spb;
};

pub const State = struct {
    time: f32,
    tags: TagSet,
    tag_times: TagVector,
    tag_times_remaining: TagVector,
    tag_durations: TagVector,
    camera: camera.State,

    pub fn uniforms(self: *const @This()) types.FrameUniforms {
        const view = math.Mat4.lookAt(
            self.camera.pos,
            self.camera.target,
            math.radians(self.camera.roll),
        );

        return .{
            .vertex = .{
                .view_projection = math.Mat4.perspective(
                    math.radians(self.camera.fov),
                    util.aspectRatio(script.config.main),
                    script.config.main.near,
                    script.config.main.far,
                ).mmul(view),
                .camera_position = .{
                    self.camera.pos[0],
                    self.camera.pos[1],
                    self.camera.pos[2],
                    1,
                },
                .camera_right = .{ view.col[0][0], view.col[1][0], view.col[2][0], 0 },
                .camera_up = .{ view.col[0][1], view.col[1][1], view.col[2][1], 0 },
                .global_time = self.time,
            },
            .fragment = .{
                .global_time = self.time,
            },
        };
    }
};

pub const Tag = blk: {
    var field_names: [timeline.tags.len][]const u8 = undefined;

    var num_fields = 0;
    outer: for (timeline.tags) |tag| {
        for (field_names[0..num_fields]) |name| {
            if (std.mem.eql(u8, tag.name, name)) continue :outer;
        }
        field_names[num_fields] = tag.name;
        num_fields += 1;
    }

    const Int = std.math.IntFittingRange(0, @max(num_fields, 2) - 1);

    break :blk @Enum(
        Int,
        .exhaustive,
        field_names[0..num_fields],
        &std.simd.iota(Int, num_fields),
    );
};

pub const TagSet = std.EnumSet(Tag);
pub const TagVector = std.EnumArray(Tag, f32);

fn resolveTagTime(comptime i: usize) f32 {
    const tag_raw = timeline.tags[i];
    switch (tag_raw.t) {
        .abs => |abs| return abs,
        .rel => |rel| {
            var iterator = std.mem.reverseIterator(timeline.tags[0..i]);
            while (iterator.next()) |tag_other| {
                if (std.mem.eql(u8, tag_other.name, rel.of)) {
                    const time = resolveTagTime(iterator.index) +
                        switch (rel.to) {
                            .start => 0,
                            .end => tag_other.duration,
                        } + rel.by;

                    if (time < 0) {
                        @compileError(std.fmt.comptimePrint(
                            "Tag \"{s}\" at index {} has negative time value",
                            .{ tag_raw.name, i },
                        ));
                    }

                    return time;
                }
            }
            @compileError("Could not find tag \"" ++ rel.of ++ "\"");
        },
        .seq => {
            if (i == 0) return 0.0;
            const prev_start = resolveTagTime(i - 1);
            const prev_duration = timeline.tags[i - 1].duration;
            return prev_start + prev_duration;
        },
    }
}

const tag_table = blk: {
    var tags: [timeline.tags.len]Tag = undefined;
    for (&tags, timeline.tags) |*tag, tag_raw| {
        tag.* = @field(Tag, tag_raw.name);
    }
    break :blk tags;
};

const tag_time_table = blk: {
    var times: [timeline.tags.len]f32 = undefined;
    for (&times, 0..) |*time, i| {
        time.* = resolveTagTime(i);
    }
    break :blk times;
};

fn resolveEventTime(comptime t: EventTime) f32 {
    switch (t) {
        .abs => |abs| return abs,
        .rel => |rel| {
            for (timeline.tags, 0..) |tag_raw, i| {
                if (std.mem.eql(u8, tag_raw.name, rel.tag)) {
                    return tag_time_table[i] + rel.by;
                }
            }
            @compileError("Could not find tag \"" ++ rel.tag ++ "\"");
        },
    }
}

const cam_control_time_table = blk: {
    var times: [timeline.camera.control.len]f32 = undefined;
    for (&times, timeline.camera.control) |*time, control| {
        time.* = resolveEventTime(control.t);
    }
    // Cam control segments are non-overlapping, assert monotonicity
    for (times[0 .. times.len - 1], times[1..]) |time0, time1| {
        std.debug.assert(time0 <= time1);
    }
    break :blk times;
};

const text_time_table = blk: {
    var times: [timeline.text.track.len]f32 = undefined;
    for (&times, timeline.text.track) |*time, text| {
        time.* = resolveEventTime(text.t);
    }
    break :blk times;
};

fn sumLen(comptime slices: anytype) usize {
    var sum = 0;
    for (slices) |slice| {
        sum += slice.len;
    }
    return sum;
}

const cam_track_table = blk: {
    const tracks = timeline.camera.tracks;

    var offset_buf: [tracks.len + 1]usize = undefined;
    var entry_buf: [sumLen(tracks)]camera.State = undefined;
    var time_buf: [sumLen(tracks)]f32 = undefined;
    var running_sum = 0;

    for (tracks, offset_buf[0..tracks.len]) |track, *offset| {
        const entry_table = entry_buf[running_sum..][0..track.len];
        const time_table = time_buf[running_sum..][0..track.len];

        offset.* = running_sum;
        entry_table.*[0] = .{
            .pos = .{ 0, 0, 1 },
            .target = .{ 0, 0, 0 },
        };
        time_table.*[0] = resolveEventTime(track[0].t);

        for (1..track.len) |i| {
            const next = track[i];
            const next_t = resolveEventTime(next.t);

            const prev = track[i - 1];
            const prev_t = time_table[i - 1];
            const prev_shift = if (i > 1) track[i - 2].blend else 0;

            // Cam segments are non-overlapping, assert monotonicity
            std.debug.assert(prev_t <= next_t);

            entry_table.*[i] = evaluateCameraSegment(
                prev,
                &entry_table[i - 1],
                prev_t,
                null,
                null,
                null,
                next_t,
                prev_shift,
            );
            time_table.*[i] = next_t;
        }

        running_sum += track.len;
    }

    std.debug.assert(running_sum == entry_buf.len);
    offset_buf[tracks.len] = running_sum;

    const offset_table = offset_buf[0..].*;
    const entry_table = entry_buf[0..].*;
    const time_table = time_buf[0..].*;

    break :blk struct {
        const offsets = offset_table;
        const entries = entry_table;
        const times = time_table;

        pub fn getEntries(i: usize) []const camera.State {
            const start = offsets[i];
            const end = offsets[i + 1];
            return entries[start..end];
        }

        pub fn getTimes(i: usize) []const f32 {
            const start = offsets[i];
            const end = offsets[i + 1];
            return times[start..end];
        }
    };
};

pub fn evaluateCameraSegment(
    segment: Camera.Segment,
    segment_entry: *const camera.State,
    segment_t: f32,
    next: ?*const Camera.Segment,
    next_entry: ?*const camera.State,
    next_t: ?f32,
    time: f32,
    time_shift: f32,
) camera.State {
    const relative_time = time - segment_t;
    var current_state = segment.entry orelse segment_entry.*;

    for (segment.motion) |motion| {
        current_state = switch (motion) {
            inline else => |param, tag| blk: {
                const func = @field(camera.fns, @tagName(tag));
                const t = relative_time + time_shift;
                break :blk func(t, current_state, param);
            },
        };
    }

    // Blend with next segment
    const blend_target = next orelse return current_state;
    const blend_target_entry = next_entry.?;
    const blend_target_t = next_t.?;

    const blend = if (segment.blend < 0) blend_target_t - segment_t else segment.blend;
    const blend_start = blend_target_t - blend;

    if (blend > 0 and time >= blend_start) {
        const elapsed_in_blend = time - blend_start;
        const t = std.math.clamp(elapsed_in_blend / blend, 0.0, 1.0);
        const alpha = math.smoothstep(t);

        const next_state = evaluateCameraSegment(
            blend_target.*,
            blend_target_entry,
            blend_target_t,
            null, // No "next next". Blend periods should not overlap.
            null,
            null,
            time,
            blend,
        );
        current_state = current_state.lerp(next_state, alpha);
    }

    return current_state;
}

pub fn evaluateCamera(
    track: []const Camera.Segment,
    entries: []const camera.State,
    times: []const f32,
    idx: usize,
    time: f32,
) camera.State {
    const segment = track[idx];
    const next: struct {
        segment: ?*const Camera.Segment,
        entry: ?*const camera.State,
        t: ?f32,
    } =
        if (idx + 1 < track.len)
            .{ .segment = &track[idx + 1], .entry = &entries[idx + 1], .t = times[idx + 1] }
        else
            .{ .segment = null, .entry = null, .t = null };

    // Time shift avoids negative interpolation on movements.
    // Otherwise the segment-relative time must be clamped non-negative,
    // so that the camera track doesn't make unexpected inverse movements
    // during blending, but then accelerations would look bad.
    const time_shift = if (idx > 0) track[idx - 1].blend else 0;

    return evaluateCameraSegment(
        segment,
        &entries[idx],
        times[idx],
        next.segment,
        next.entry,
        next.t,
        time,
        time_shift,
    );
}

const cam_effect_time_table = blk: {
    var times: [timeline.camera.effects.len]f32 = undefined;
    for (&times, timeline.camera.effects) |*time, effect| {
        time.* = resolveEventTime(effect.t);
    }
    break :blk times;
};

pub fn applyCameraEffects(
    effects: []const Camera.Effect,
    base_state: camera.State,
    time: f32,
) camera.State {
    var state = base_state;

    for (effects, cam_effect_time_table) |effect, effect_t| {
        const start = effect_t;
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
        intensity = math.smoothstep(intensity);

        state = switch (effect.motion) {
            inline else => |param, tag| blk: {
                const func = @field(camera.fns, @tagName(tag));

                var mod_param = param;
                if (hasParam(param, "amp")) mod_param.amp *= intensity; // shake, wave, swivel
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

inline fn getAnchor(a: Anchor) Vec3 {
    if (@typeInfo(Anchor).@"enum".fields.len == 0) unreachable;
    return switch (a) {
        inline else => |tag| @field(script.anchor, @tagName(tag)),
    };
}

fn scanNonOverlapping(time_table: []const f32, time: f32) usize {
    for (time_table, 0..) |t, i| {
        if (time < t) {
            return i -| 1;
        }
    }

    return time_table.len - 1;
}

pub fn resolve(time: f32) State {
    var tags_active: TagSet = .empty;
    var tag_times: TagVector = .initFill(-1);
    var tag_times_remaining: TagVector = .initFill(-1);
    var tag_durations: TagVector = .initFill(-1);
    for (timeline.tags, tag_table, tag_time_table) |tag_raw, tag, tag_t| {
        const tag_time = time - tag_t;
        const tag_duration = tag_raw.duration;
        const tag_time_remaining = tag_duration - tag_time;
        if (tag_time >= 0 and tag_time_remaining > 0) {
            tags_active.insert(tag);
            tag_times.set(tag, tag_time);
            tag_times_remaining.set(tag, tag_time_remaining);
            tag_durations.set(tag, tag_duration);
        }
    }

    const cam_control_idx = scanNonOverlapping(&cam_control_time_table, time);
    const cam_control = timeline.camera.control[cam_control_idx];
    const cam_track = timeline.camera.tracks[cam_control.i];
    const cam_entries = cam_track_table.getEntries(cam_control.i);
    const cam_times = cam_track_table.getTimes(cam_control.i);
    const cam_idx = scanNonOverlapping(cam_times, time);
    var cam_state = evaluateCamera(
        cam_track,
        cam_entries,
        cam_times,
        cam_idx,
        time,
    );

    var blend_alpha: f32 = 0.0;
    const next_control_idx = cam_control_idx + 1;

    // Check if we are transitioning to the next control segment
    if (next_control_idx < timeline.camera.control.len) {
        const next_ctrl_t = cam_control_time_table[next_control_idx];
        const blend_start = next_ctrl_t - cam_control.blend;

        if (cam_control.blend > 0 and time >= blend_start) {
            const t = std.math.clamp(
                (time - blend_start) / cam_control.blend,
                0.0,
                1.0,
            );
            blend_alpha = math.smoothstep(t);
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
        pos_offset = math.vec3.lerp(pos_offset, next_offset, blend_alpha);
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
        look_target = math.vec3.lerp(look_target, next_look, blend_alpha);
    }

    cam_state.target = look_target;

    // Finally, apply effects
    const cam = applyCameraEffects(timeline.camera.effects, cam_state, time);

    return .{
        .time = time,
        .tags = tags_active,
        .tag_times = tag_times,
        .tag_times_remaining = tag_times_remaining,
        .tag_durations = tag_durations,
        .camera = cam,
    };
}

pub const InstanceText = extern struct {
    uv: [4]f32,
    position: [4]f32,
    color: [4]f32,
    style: [2]u8, // .x = font, .y = effect

    pub const locations = .{ 8, 9, 10, 11 };
};

var font_sizes: [timeline.text.fonts.len]f32 = undefined;
var font_glyphs: [timeline.text.fonts.len][128]Font.Atlas.Glyph = undefined;

pub fn FontAtlas(io: *const std.Io, gpa: *const std.mem.Allocator) type {
    return struct {
        pub fn create() !TextureInfo {
            return .{
                .tex_type = .@"2d_array",
                .format = .r8_unorm,
                .width = 1024, // TODO: will be replaced soon
                .height = 1024,
                .depth = @intCast(timeline.text.fonts.len),
            };
        }

        pub fn init(dst: []u8) !void {
            const layer_size = 1024 * 1024;

            for (
                timeline.text.fonts,
                &font_sizes,
                &font_glyphs,
                0..,
            ) |def, *size, *glyph_info, i| {
                size.* = def.size;
                const ttf = try util.loadFile(io.*, gpa.*, def.file);
                defer gpa.free(ttf);

                try font.bakeSDFAtlas(
                    ttf.ptr,
                    def.size,
                    10, // TODO: will be replaced soon
                    8,
                    1024,
                    1024,
                    glyph_info,
                    dst.ptr + layer_size * i,
                );
            }
        }
    };
}

fn genText(
    dst: []InstanceText,
    str: []const u8,
    height_scale: f32,
    origin: Font.Origin,
    pos_ndc: [2]f32,
    color: [4]f32,
    font_idx: usize,
    effect: u8,
) u32 {
    const ndc_per_pixel_y = (height_scale * 2.0) / font_sizes[font_idx];
    const ndc_per_pixel_x = ndc_per_pixel_y / util.aspectRatio(script.config.main);
    const line_height = font_sizes[font_idx] * ndc_per_pixel_y;

    // Measure bounding box
    var max_width: f32 = 0;
    var line_width: f32 = 0;
    var num_lines: f32 = 1;

    for (str) |char| {
        if (char == '\n') {
            max_width = @max(max_width, line_width);
            line_width = 0;
            num_lines += 1;
            continue;
        }
        if (char == ' ') {
            line_width += (font_sizes[font_idx] / 2.0) * ndc_per_pixel_x;
        } else {
            line_width += font_glyphs[font_idx][char].advance * ndc_per_pixel_x;
        }
    }
    max_width = @max(max_width, line_width);
    const total_height = num_lines * line_height;

    // Calculate origin
    var cursor_x = pos_ndc[0];
    var cursor_y = pos_ndc[1] - line_height;

    switch (origin) {
        .left => {
            cursor_y += total_height * 0.5;
        },
        .right => {
            cursor_x -= max_width;
            cursor_y += total_height * 0.5;
        },
        .top => {
            cursor_x -= max_width * 0.5;
        },
        .bottom => {
            cursor_x -= max_width * 0.5;
            cursor_y += total_height;
        },
        .top_left => {},
        .top_right => {
            cursor_x -= max_width;
        },
        .bottom_left => {
            cursor_y += total_height;
        },
        .bottom_right => {
            cursor_x -= max_width;
            cursor_y += total_height;
        },
        .center => {
            cursor_x -= max_width * 0.5;
            cursor_y += (total_height * 0.5);
        },
    }

    const start_x = cursor_x;

    // Generate instances
    @memset(dst, std.mem.zeroes(InstanceText));
    var instances: u32 = 0;

    for (str) |char| {
        if (instances >= dst.len) break;

        if (char == '\n') {
            cursor_y -= line_height;
            cursor_x = start_x;
            continue;
        }

        if (char == ' ') {
            cursor_x += (font_sizes[font_idx] / 2.0) * ndc_per_pixel_x;
            continue;
        }

        const g = font_glyphs[font_idx][char];

        const top = cursor_y - (g.y_off * ndc_per_pixel_y);
        const bottom = top - (g.height * ndc_per_pixel_y);
        const left = cursor_x + (g.x_off * ndc_per_pixel_x);
        const right = left + (g.width * ndc_per_pixel_x);

        dst[instances] = .{
            .uv = .{ g.uv_min[0], g.uv_min[1], g.uv_max[0], g.uv_max[1] },
            .position = .{ left, top, right, bottom },
            .color = color,
            .style = .{ @intCast(font_idx), effect },
        };

        cursor_x += g.advance * ndc_per_pixel_x;
        instances += 1;
    }

    return instances;
}

pub const text_instances = struct {
    pub const Layout = InstanceText;

    const buf_size = 4096;
    var num_elements: u32 = 0;

    pub fn create() !u32 {
        return buf_size;
    }

    pub fn updateData(dst: []Layout) !void {
        num_elements = 0;
        const time = script.frame.state.time;

        for (timeline.text.track, text_time_table) |track, track_t| {
            if (time < track_t or time >= track_t + track.duration) continue;

            const local_t = time - track_t;
            const remaining = track.duration - local_t;

            // Resolve string
            const full_text = switch (track.text) {
                .str => |s| s,
                .ref => |r| switch (r) {
                    inline else => |tag| @field(script.string, @tagName(tag)),
                },
            };

            // Fade in
            var in_progress: f32 = 1.0;
            if (track.fade_in > 0 and local_t < track.fade_in) {
                const t = local_t / track.fade_in;
                in_progress = math.smoothstep(t);
            }
            var alpha: f32 = in_progress;

            // Fade out
            if (track.fade_out > 0 and remaining < track.fade_out) {
                const t = remaining / track.fade_out;
                alpha *= math.smoothstep(t);
            }

            var draw_text = full_text;
            var pos = track.pos;
            var color = track.color;

            if (track.anim) |anim| {
                switch (anim) {
                    .typewriter => {
                        const t = local_t / if (track.fade_in > 0)
                            track.fade_in
                        else
                            track.duration;
                        const ratio = std.math.clamp(t, 0.0, 1.0);

                        const len_f32: f32 = @floatFromInt(full_text.len);
                        const count: usize = @intFromFloat(len_f32 * ratio);
                        draw_text = full_text[0..count];
                    },
                    .slide => |offset| {
                        const factor = 1.0 - in_progress;
                        pos += offset * @as(Vec2, @splat(factor));
                    },
                    .fade => |start_color| {
                        color = math.vec4.lerp(start_color, track.color, in_progress);
                    },
                }
            }

            // Fade in and out
            color[3] *= alpha;

            // Generate instances
            num_elements += genText(
                dst[num_elements..],
                draw_text,
                track.scale,
                track.origin,
                pos,
                color,
                track.font,
                @intFromEnum(track.effect),
            );
        }
    }

    pub fn updateInfo(info: *BufferInfo) void {
        info.num_elements = num_elements;
    }
};
