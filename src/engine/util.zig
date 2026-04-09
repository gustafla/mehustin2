const std = @import("std");

const math = @import("math.zig");
const resource = @import("resource.zig");

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

pub fn loadFile(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try resource.dataFilePath(gpa, name);
    defer gpa.free(path);
    return try resource.loadFileZ(gpa, path);
}

pub fn hslToRgb(hsl: math.Vec3) math.Vec3 {
    const c = (1 - @abs(2 * hsl[2] - 1)) * hsl[1];
    const h = hsl[0] / 60.0;
    const x = c * (1 - @abs(@mod(h, 2) - 1));
    const r, const g, const b =
        if (0 <= h and h < 1)
            .{ c, x, 0 }
        else if (1 <= h and h < 2)
            .{ x, c, 0 }
        else if (2 <= h and h < 3)
            .{ 0, c, x }
        else if (3 <= h and h < 4)
            .{ 0, x, c }
        else if (4 <= h and h < 5)
            .{ x, 0, c }
        else
            .{ c, 0, x };
    const m = hsl[2] - c / 2;
    return .{ r + m, g + m, b + m };
}

pub fn aspectRatio(comptime config: anytype) comptime_float {
    return @as(comptime_float, config.width) / @as(comptime_float, config.height);
}
