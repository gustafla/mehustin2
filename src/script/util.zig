const std = @import("std");

const resource = @import("../resource.zig");
const font = @import("font.zig");

pub const InstanceText = extern struct {
    uv: [4]f32,
    position: [4]f32,
    color: [4]f32,

    pub const locations = .{ 6, 7, 8 };
};

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

pub fn genText(
    dst: []InstanceText,
    str: []const u8,
    size: f32,
    glyphs: *[128]font.GlyphInfo,
) u32 {
    @memset(dst, std.mem.zeroes(InstanceText));

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

        dst[instances] = .{
            .uv = .{ g.uv_min[0], g.uv_min[1], g.uv_max[0], g.uv_max[1] },
            .position = .{
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

pub fn loadFile(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try resource.dataFilePath(gpa, name);
    defer gpa.free(path);
    return try resource.loadFileZ(gpa, path);
}
