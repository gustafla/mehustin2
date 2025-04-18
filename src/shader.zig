const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root");
const config = root.config;
const c = root.c;

const Stage = enum(c_int) {
    vert = c.SDL_GPU_SHADERSTAGE_VERTEX,
    frag = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
};

pub const ShaderData = struct {
    data: []const u8,
    stage: c_int,
};

pub fn loadShader(alloc: Allocator, name: []const u8) !ShaderData {
    // Determine shader stage from extension
    const extension = std.fs.path.extension(name);
    if (extension.len == 0) return error.NoStageExtension;
    const stage = std.meta.stringToEnum(Stage, extension[1..]) orelse return error.NoStageExtension;

    // Allocate relative path to SPIR-V file
    const spirv_name = try std.mem.concat(alloc, u8, &[_][]const u8{ name, ".spv" });
    defer alloc.free(spirv_name);
    const path = try std.fs.path.join(alloc, &[_][]const u8{ config.data_dir, config.shader_dir, spirv_name });
    defer alloc.free(path);

    // Load SPIR-V binary
    root.res_log.info("Loading {s}\n", .{path});
    const file = try std.fs.cwd().openFile(name, .{});
    const data = try file.readToEndAlloc(alloc, 1024 * 1024);

    return .{
        .data = data,
        .stage = @intFromEnum(stage),
    };
}
