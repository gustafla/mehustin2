const std = @import("std");
const options = @import("options");
const config = @import("config.zon");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.resource);

pub fn dataFilePath(gpa: Allocator, name: []const u8) ![:0]const u8 {
    log.info("Loading {s}", .{name});
    const data_dir = if (options.render_dynlib) options.data_dir else config.data_dir;
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
