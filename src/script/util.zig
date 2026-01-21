const std = @import("std");

const resource = @import("../resource.zig");
const font = @import("font.zig");

pub fn interleave(
    T: type,
    lengths: []const usize,
    srcs: []const []const T,
    byte_pitch: usize,
    dst: []u8,
) void {
    std.debug.assert(lengths.len == srcs.len);
    const pitch = blk: {
        var s: usize = 0;
        for (lengths) |len| {
            s += len;
        }
        break :blk s;
    };
    std.debug.assert(pitch * @sizeOf(T) == byte_pitch);
    const dst_cast: []T = @ptrCast(@alignCast(dst));

    for (0..dst.len / byte_pitch) |i| {
        var offset = i * pitch;
        for (lengths, srcs) |len, src| {
            @memcpy(dst_cast[offset..][0..len], src[i * len ..][0..len]);
            offset += len;
        }
    }
}

pub fn genText(
    str: []const u8,
    size: f32,
    glyphs: *[128]font.GlyphInfo,
    byte_pitch: usize,
    dst: []u8,
) u32 {
    const TextInstance = extern struct {
        uv_rect: [4]f32,
        pos_rect: [4]f32,
        color: [4]f32,
    };
    std.debug.assert(@sizeOf(TextInstance) == byte_pitch);
    const dst_cast: []TextInstance = @ptrCast(@alignCast(dst));

    @memset(dst_cast, std.mem.zeroes(TextInstance));

    var x: f32 = 0;
    var y: f32 = size;
    var instances: u32 = 0;

    for (str) |char| {
        const g = glyphs[char];

        if (char == '\n') {
            y += size;
            x = 0;
            continue;
        }

        if (char == ' ') {
            x += size / 2;
            continue;
        }

        const p_min_x = x + g.x_off;
        const p_min_y = y + g.y_off;

        dst_cast[instances] = .{
            .uv_rect = .{ g.uv_min[0], g.uv_min[1], g.uv_max[0], g.uv_max[1] },
            .pos_rect = .{
                p_min_x,
                p_min_y,
                p_min_x + g.width,
                p_min_y + g.height,
            },
            .color = @splat(1),
        };

        x += g.advance;
        instances += 1;
    }

    return instances;
}

pub fn loadFile(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try resource.dataFilePath(gpa, name);
    defer gpa.free(path);
    return try resource.loadFileZ(gpa, path);
}
