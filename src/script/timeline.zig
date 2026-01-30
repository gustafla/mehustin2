const std = @import("std");

const timeline: Timeline = @import("../timeline.zon");

const math = @import("../math.zig");
const vec3 = math.vec3;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec4 = math.vec4;
const render = @import("../render.zig");
const script = @import("../script.zig");
const Anchor = script.Anchor;
const camera = @import("camera.zig");
const font = @import("font.zig");
const util = @import("util.zig");

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

pub const Font = struct {
    name: []const u8,
    size: f32,
    padding: u32,
    dist_scale: f32 = 4,
};

pub const TextSegment = struct {
    t: f32,
    duration: f32,
    text: union(enum) {
        str: []const u8, // Inline string
        ref: []const u8, // script.zig reflection
    },
    font: usize,
    pos: Vec2, // NDC position
    scale: f32 = 0.1, // Fraction of screen height
    origin: TextOrigin,
    color: Vec4 = @splat(1),
    anim: ?union(enum) {
        fade: Vec4, // Fade from & to a color value
        slide: Vec2, // Slide from & to an NDC position
        typewriter, // Reveal & remove text letter by letter
    } = null,
    fade_in: f32 = 0,
    fade_out: f32 = 0,
};

pub const Timeline = struct {
    clip_track: []const ClipSegment,
    camera: struct {
        control: []const CameraControl,
        tracks: []const []const camera.Segment,
        effects: []const camera.Effect,
    },
    text: struct {
        atlas_size: u32 = 1024,
        fonts: []const Font,
        track: []const TextSegment,
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

pub const TextOrigin = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    center,
};

pub const InstanceText = extern struct {
    uv: [4]f32,
    position: [4]f32,
    color: [4]f32,
    style: [2]u8, // .x = font, .y = effect

    pub const locations = .{ 6, 7, 8, 9 };
};

var font_sizes: [timeline.text.fonts.len]f32 = undefined;
var font_glyphs: [timeline.text.fonts.len][128]font.GlyphInfo = undefined;

pub const font_atlas = struct {
    pub fn create() !script.TextureInfo {
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
            const ttf = try util.loadFile(script.gpa, def.name);
            defer script.gpa.free(ttf);

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

fn genText(
    dst: []InstanceText,
    str: []const u8,
    height_scale: f32,
    origin: TextOrigin,
    pos_ndc: [2]f32,
    color: [4]f32,
    font_idx: usize,
    effect: u8,
) u32 {
    const ndc_per_pixel_y = (height_scale * 2.0) / font_sizes[font_idx];
    const ndc_per_pixel_x = ndc_per_pixel_y / render.aspect;

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
    const total_height = num_lines * (font_sizes[font_idx] * ndc_per_pixel_y);

    // Calculate origin
    var cursor_x = pos_ndc[0];
    var cursor_y = pos_ndc[1];

    switch (origin) {
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
            cursor_y += total_height * 0.5;
        },
    }

    const start_x = cursor_x;

    // Generate instances
    @memset(dst, std.mem.zeroes(InstanceText));
    var instances: u32 = 0;

    for (str) |char| {
        if (instances >= dst.len) break;

        if (char == '\n') {
            cursor_y -= (font_sizes[font_idx] * ndc_per_pixel_y);
            cursor_x = start_x;
            continue;
        }

        if (char == ' ') {
            cursor_x += (font_sizes[font_idx] / 2.0) * ndc_per_pixel_x;
            continue;
        }

        const g = font_glyphs[font_idx][char];

        const top = cursor_y + (g.y_off * ndc_per_pixel_y);
        const bottom = top - (g.height * ndc_per_pixel_y);
        const left = cursor_x + (g.x_off * ndc_per_pixel_x);
        const right = left + (g.width * ndc_per_pixel_x);

        dst[instances] = .{
            .uv = .{ g.uv_min[0], g.uv_min[1], g.uv_max[0], g.uv_max[1] },
            .position = .{ left, bottom, right, top },
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
        const time = script.frame.time;

        for (timeline.text.track) |track| {
            if (time < track.t or time >= track.t + track.duration) continue;

            const local_t = time - track.t;
            const remaining = track.duration - local_t;

            // Resolve string
            const full_text = switch (track.text) {
                .str => |s| s,
                .ref => unreachable, // TODO: Needs enum + inline switch case
            };

            // Fade in
            var in_progress: f32 = 1.0;
            if (track.fade_in > 0 and local_t < track.fade_in) {
                const t = local_t / track.fade_in;
                in_progress = t * t * (3.0 - 2.0 * t);
            }
            var alpha: f32 = in_progress;

            // Fade out
            if (track.fade_out > 0 and remaining < track.fade_out) {
                const t = remaining / track.fade_out;
                alpha *= t * t * (3.0 - 2.0 * t);
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
                        color = vec4.lerp(start_color, track.color, in_progress);
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
                0, // No effects for now
            );
        }
    }

    pub fn updateInfo() script.BufferInfo {
        return .{ .num_elements = num_elements };
    }
};
