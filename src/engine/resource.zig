const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const config = @import("config.zon");
const options = @import("options");

const log = std.log.scoped(.resource);
const data_dir = if (builtin.mode == .Debug) options.data_dir else config.data_dir;

pub fn dataFilePath(gpa: Allocator, name: []const u8) ![:0]const u8 {
    log.info("Loading {s}", .{name});
    return std.fs.path.joinZ(gpa, &.{ data_dir, name });
}

pub fn loadFileZ(gpa: Allocator, path: []const u8) ![:0]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buffer = try gpa.allocSentinel(u8, stat.size, 0);
    std.debug.assert(try file.readAll(buffer[0..]) == stat.size);
    return buffer;
}
