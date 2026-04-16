const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const script = @import("script");
const config = script.config.main;

const log = std.log.scoped(.resource);

pub fn dataFilePath(gpa: Allocator, name: []const u8) ![:0]const u8 {
    log.info("Loading {s}", .{name});

    return std.fs.path.joinZ(gpa, &.{
        script.config.main.data_dir,
        name,
    });
}

pub fn loadFileZ(io: std.Io, gpa: Allocator, path: []const u8) ![:0]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buffer = try gpa.allocSentinel(u8, stat.size, 0);
    const read_bytes = try std.Io.File.readPositionalAll(file, io, buffer[0..], 0);
    std.debug.assert(read_bytes == stat.size);
    return buffer;
}
