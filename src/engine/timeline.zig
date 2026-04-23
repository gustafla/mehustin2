const std = @import("std");

const script = @import("script");
const Anchor = script.Anchor;
const timeline = script.config.timeline;

const camera = @import("camera.zig");
const font = @import("font.zig");
const math = @import("math.zig");
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const schema = @import("schema.zig");
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
    for (timeline.tags) |tag| last = @max(last, tag.t + tag.duration);
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

fn resolveTagTime(comptime i: usize, comptime field: []const u8) f32 {
    const tag_raw = timeline.tags[i];
    const t = @field(tag_raw, field);
    switch (t) {
        .abs => |abs| return abs,
        .rel => |rel| {
            var iterator = std.mem.reverseIterator(timeline.tags[0..i]);
            while (iterator.next()) |tag_other| {
                if (std.mem.eql(u8, tag_other.name, rel.to)) {
                    const time = resolveTagTime(
                        iterator.index,
                        field,
                    ) + rel.by;
                    if (time < 0) {
                        @compileError(std.fmt.comptimePrint(
                            "Tag \"{s}\" at index {} yields negative {s} value",
                            .{ tag_raw.name, i, field },
                        ));
                    }
                    return time;
                }
            }
            @compileError("Could not find tag \"" ++ rel.to ++ "\"");
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
        time.* = resolveTagTime(i, "t");
    }
    break :blk times;
};

const tag_duration_table = blk: {
    var times: [timeline.tags.len]f32 = undefined;
    for (&times, 0..) |*time, i| {
        time.* = resolveTagTime(i, "duration");
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
    if (@typeInfo(Anchor).@"enum".fields.len == 0) unreachable;
    return switch (a) {
        inline else => |tag| @field(script.anchor, @tagName(tag)),
    };
}

fn scanNonOverlapping(slice: anytype, time: f32) usize {
    for (slice, 0..) |unit, i| {
        if (time < unit.t) {
            return i -| 1;
        }
    }

    return slice.len - 1;
}

pub fn resolve(time: f32) State {
    var tags_active: TagSet = .empty;
    var tag_times: TagVector = .initFill(-1);
    var tag_times_remaining: TagVector = .initFill(-1);
    var tag_durations: TagVector = .initFill(-1);
    for (tag_table, tag_time_table, tag_duration_table) |tag, tag_t, tag_duration| {
        const tag_time = time - tag_t;
        const tag_time_remaining = tag_duration - tag_time;
        if (tag_time > 0 and tag_time_remaining > 0) {
            tags_active.insert(tag);
            tag_times.set(tag, tag_time);
            tag_times_remaining.set(tag, tag_time_remaining);
            tag_durations.set(tag, tag_duration);
        }
    }

    const cam_control_idx = scanNonOverlapping(timeline.camera.control, time);
    const cam_control = timeline.camera.control[cam_control_idx];
    const cam_track = timeline.camera.tracks[cam_control.i];
    const cam_idx = scanNonOverlapping(cam_track, time);
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
    const cam = camera.applyEffects(timeline.camera.effects, cam_state, time);

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
var font_glyphs: [timeline.text.fonts.len][128]font.GlyphInfo = undefined;

pub fn FontAtlas(io: *const std.Io, gpa: *const std.mem.Allocator) type {
    return struct {
        pub fn create() !TextureInfo {
            return .{
                .tex_type = .@"2d_array",
                .format = .r8_unorm,
                .width = timeline.text.atlas_size,
                .height = timeline.text.atlas_size,
                .depth = @intCast(timeline.text.fonts.len),
            };
        }

        pub fn init(dst: []u8) !void {
            const layer_size =
                timeline.text.atlas_size *
                timeline.text.atlas_size;

            for (
                timeline.text.fonts,
                &font_sizes,
                &font_glyphs,
                0..,
            ) |def, *size, *glyph_info, i| {
                size.* = def.size;
                const ttf = try util.loadFile(io.*, gpa.*, def.name);
                defer gpa.free(ttf);

                try font.bakeSDFAtlas(
                    ttf.ptr,
                    def.size,
                    def.padding,
                    def.dist_scale,
                    timeline.text.atlas_size,
                    timeline.text.atlas_size,
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
    origin: schema.Timeline.TextOrigin,
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

        for (timeline.text.track) |track| {
            if (time < track.t or time >= track.t + track.duration) continue;

            const local_t = time - track.t;
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
