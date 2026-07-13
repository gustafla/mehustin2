const std = @import("std");
const builtin = @import("builtin");

const c = @import("c");
const options = @import("options");
const script = @import("script");

const math = @import("math.zig");
const resource = @import("resource.zig");
const timeline = @import("timeline.zig");

var fps_frames: u32 = 0;
var fps_ticks: u64 = 0;
var debug_str_buf: [1024]u8 = undefined;
var captured_frames: std.atomic.Value(u64) = .init(0);

pub fn updateDebugStrings(state: timeline.State, fps_str: *[]const u8, time_str: *[]const u8) void {
    var writer = std.Io.Writer.fixed(&debug_str_buf);

    if (options.show_fps) {
        fps_frames += 1;
        const ticks = c.SDL_GetTicksNS();
        if (fps_ticks + c.SDL_NS_PER_SECOND < ticks) {
            writer.print("FPS: {}", .{fps_frames}) catch unreachable;
            fps_str.* = writer.buffered();
            fps_ticks = ticks;
            fps_frames = 0;
        }
    }
    writer = .fixed(writer.buffer[fps_str.len..]);

    if (builtin.mode == .Debug) {
        writer.print("t={:.1} ", .{state.time}) catch unreachable;
        var iterator = state.tags.iterator();
        while (iterator.next()) |tag| {
            const ttag = timeline.mapTag(tag) orelse continue;
            const t = state.tag_times.get(ttag);
            writer.print("{t}={:.1} ", .{ ttag, t }) catch unreachable;
        }
        time_str.* = writer.buffered();
    }
    writer = .fixed(writer.buffer[fps_str.len..]);
}

pub fn interleave(
    comptime E: type,
    dst: []E,
    srcs: anytype,
) void {
    const fields = @typeInfo(E).@"struct".fields;

    for (dst, 0..) |*d, i| {
        inline for (fields, srcs) |field, src| {
            const dst_field_ptr = &@field(d, field.name);

            switch (@typeInfo(field.type)) {
                .array => |info| {
                    const slice = @as([]const info.child, src);
                    const chunk = slice[i * info.len ..][0..info.len];
                    @memcpy(dst_field_ptr, chunk);
                },
                else => {
                    dst_field_ptr.* = src[i];
                },
            }
        }
    }
}

pub fn writeSSBO(
    comptime Header: type,
    comptime Element: type,
    dst: []u8,
    header: Header,
    elements: []const Element,
) void {
    std.debug.assert(dst.len >= @sizeOf(Header) + (@sizeOf(Element) * elements.len));
    @memcpy(dst[0..@sizeOf(Header)], std.mem.asBytes(&header));

    const element_dst_bytes = dst[@sizeOf(Header)..][0 .. @sizeOf(Element) * elements.len];
    const element_dst = std.mem.bytesAsSlice(Element, element_dst_bytes);
    @memcpy(element_dst, elements);
}

pub fn ambientFromEnvmap(
    w: anytype,
    h: anytype,
    data: [*]const f32,
    comptime p: struct {
        clamp_max: f32 = 10.0,
        y_range_start: f32 = 0.0,
        y_range_end: f32 = 0.5, // Upper half by default (sky)
    },
) math.Vec4 {
    var sky_color: math.Vec4 = @splat(0);
    var total_weight: f32 = 0.0;

    const wu: usize = @intCast(w);
    const h_f32: f32 = @floatFromInt(h);

    for (@intFromFloat(h_f32 * p.y_range_start)..@intFromFloat(h_f32 * p.y_range_end)) |y| {
        const v = (@as(f32, @floatFromInt(y)) + 0.5) / h_f32;
        const theta = std.math.pi * v;
        const weight = @sin(theta);
        const weight_vec: math.Vec4 = @splat(weight);

        for (0..wu) |x| {
            const i = (y * wu + x) * 4;
            const color: math.Vec4 = .{ data[i], data[i + 1], data[i + 2], data[i + 3] };
            const clamped = std.math.clamp(
                color,
                @as(math.Vec4, @splat(0.0)),
                @as(math.Vec4, @splat(p.clamp_max)),
            );
            sky_color += clamped * weight_vec;
            total_weight += weight;
        }
    }
    sky_color /= @as(math.Vec4, @splat(total_weight));

    return sky_color;
}

pub fn loadFile(io: std.Io, gpa: std.mem.Allocator, name: []const u8) ![:0]u8 {
    const path = try resource.dataFilePath(gpa, name);
    defer gpa.free(path);
    return try resource.loadFileZ(io, gpa, path);
}

pub fn hslToRgb(hsl: math.Vec3) math.Vec3 {
    const cc = (1 - @abs(2 * hsl[2] - 1)) * hsl[1];
    const h = hsl[0] / 60.0;
    const x = cc * (1 - @abs(@mod(h, 2) - 1));
    const r, const g, const b =
        if (0 <= h and h < 1)
            .{ cc, x, 0 }
        else if (1 <= h and h < 2)
            .{ x, cc, 0 }
        else if (2 <= h and h < 3)
            .{ 0, cc, x }
        else if (3 <= h and h < 4)
            .{ 0, x, cc }
        else if (4 <= h and h < 5)
            .{ x, 0, cc }
        else
            .{ cc, 0, x };
    const m = hsl[2] - cc / 2;
    return .{ r + m, g + m, b + m };
}

pub fn aspectRatio(comptime config: anytype) comptime_float {
    return @as(comptime_float, config.width) / @as(comptime_float, config.height);
}

pub fn capturePNG(rgba_src: []const u8) !void {
    const frame = captured_frames.fetchAdd(1, .monotonic);
    var buf: [128]u8 = @splat(0);
    const filename = std.fmt.bufPrint(&buf, "frame{}.png", .{frame}) catch unreachable;
    if (c.stbi_write_png(
        filename.ptr,
        script.config.main.width,
        script.config.main.height,
        4,
        rgba_src.ptr,
        script.config.main.width * 4,
    ) == 0) std.log.err("Failed to save {s}", .{filename});
}
