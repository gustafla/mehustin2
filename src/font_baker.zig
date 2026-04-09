const std = @import("std");
const font = @import("script/font.zig");
const c = @cImport({
    @cInclude("stb_truetype.h");
});

pub fn main() !void {
    // var dba: std.heap.DebugAllocator(.{}) = .init;
    // var gpa = dba.allocator();

    var font_info: struct {
        name: []const u8,
        size: f32,
        atlas_size: u32,
        padding: u32,
        dist_scale: u8,
    } = undefined;
    const fields = @typeInfo(@TypeOf(font_info)).@"struct".fields;
    var args = std.process.args();

    var i: usize = 0;
    while (args.next()) |arg| {
        const field = fields[i];
        switch (field.type) {
            []const u8 => {
                @field(font_info, field.name) = arg;
            },
            f32, u32, u8 => {
                const num = std.fmt.parseInt(field.type, arg, 0) catch unreachable;
                @field(font_info, field.name) = num;
            },
            else => unreachable,
        }
        i += 1;
    }
}
