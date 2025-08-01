const std = @import("std");

pub const log = std.log.scoped(.res);

const BUF_SIZE = 64;
var path_buf: [BUF_SIZE]u8 = undefined;

pub const conf: struct {
    width: u32,
    height: u32,
    data_dir: []const u8,
    shader_dir: []const u8,
} = @import("config.zon");

fn pathZ(a: []const u8, b: []const u8) ![:0]const u8 {
    const path_len = a.len + 1 + b.len;
    if (path_len + 1 > BUF_SIZE) {
        return error.DataFilePathTooLong;
    }
    @memset(&path_buf, 0);
    @memcpy(path_buf[0..a.len], a);
    path_buf[a.len] = std.fs.path.sep;
    @memcpy(path_buf[a.len + 1 .. path_len], b);
    log.info("Loading {s}", .{path_buf[0..path_len]});
    return @ptrCast(path_buf[0..path_len]);
}

pub fn dataFilePath(name: []const u8) ![:0]const u8 {
    return pathZ(conf.data_dir, name);
}

pub fn shaderFilePath(name: []const u8) ![:0]const u8 {
    return pathZ(conf.shader_dir, name);
}

pub fn loadFileZ(alloc: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buffer = try alloc.allocSentinel(u8, stat.size, 0);
    std.debug.assert(try file.readAll(buffer[0..]) == stat.size);
    return buffer;
}
