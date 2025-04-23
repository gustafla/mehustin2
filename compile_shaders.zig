const std = @import("std");
const shaderc = @import("src/shader/compiler.zig");
const log = std.log.scoped(.shaders);
const config_path = "src/config.zon";
const Config = struct {
    data_dir: []const u8,
    shader_dir: []const u8,
};
const Allocator = std.mem.Allocator;

fn compileFile(alloc: Allocator, input_path: [:0]const u8, output_path: []const u8) !void {
    const glsl = try shaderc.loadFileNullTerminated(alloc, input_path);
    defer alloc.free(glsl);

    const file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();

    const spirv = shaderc.compileShader(alloc, glsl, input_path) catch |err| {
        log.err("{s}", .{shaderc.shader_err.load()});
        return err;
    };
    defer alloc.free(spirv);

    try file.writeAll(spirv);
}

pub fn main() !void {
    log.info("Loading {s}", .{config_path});

    // Initialize allocator
    var allocator = std.heap.DebugAllocator(.{}).init;
    var arena = std.heap.ArenaAllocator.init(allocator.allocator());
    defer arena.deinit();
    const alloc = arena.allocator();

    // Load config
    const zon = try shaderc.loadFileNullTerminated(alloc, config_path);
    const config: Config = try std.zon.parse.fromSlice(Config, alloc, zon, null, .{ .ignore_unknown_fields = true });

    // Create output directories
    const output_dir = try std.fs.path.join(alloc, &[_][]const u8{ config.data_dir, config.shader_dir });
    try std.fs.cwd().makePath(output_dir);

    // Iterate shader source directory
    var source_dir = try std.fs.cwd().openDir(config.shader_dir, .{ .iterate = true });
    defer source_dir.close();
    var iter = source_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        // Define input and output paths
        const input_path = try std.fs.path.joinZ(alloc, &[_][]const u8{ config.shader_dir, entry.name });
        const output_file = try std.mem.join(alloc, ".", &[_][]const u8{ entry.name, "spv" });
        const output_path = try std.fs.path.join(alloc, &[_][]const u8{ output_dir, output_file });

        // Invoke shaderc
        log.info("Compiling {s} to {s}", .{ input_path, output_path });
        try compileFile(alloc, input_path, output_path);
    }
}
