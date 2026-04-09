const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const script = @import("script");
const config = script.config.main;

const log = std.log.scoped(.resource);

pub fn dataFilePath(gpa: Allocator, name: []const u8) ![:0]const u8 {
    log.info("Loading {s}", .{name});
    return std.fs.path.joinZ(gpa, &.{
        if (builtin.mode == .Debug)
            "zig-out/bin/data" // TODO: un-hardcode this
        else
            script.config.main.data_dir,
        name,
    });
}

pub fn loadFileZ(gpa: Allocator, path: []const u8) ![:0]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buffer = try gpa.allocSentinel(u8, stat.size, 0);
    std.debug.assert(try file.readAll(buffer[0..]) == stat.size);
    return buffer;
}
