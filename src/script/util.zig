const std = @import("std");

const resource = @import("../resource.zig");

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

pub fn loadFile(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try resource.dataFilePath(gpa, name);
    defer gpa.free(path);
    return try resource.loadFileZ(gpa, path);
}
