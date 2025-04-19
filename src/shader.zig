const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root");
const sdlerr = root.sdlerr;
const config = root.config;
const c = root.c;

const Stage = enum(c_uint) {
    vert = c.SDL_GPU_SHADERSTAGE_VERTEX,
    frag = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
};

pub fn loadShader(alloc: Allocator, device: *c.SDL_GPUDevice, name: []const u8) !*c.SDL_GPUShader {
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
    root.res_log.info("Loading {s}", .{path});
    const file = try std.fs.cwd().openFile(path, .{});
    const data = try file.readToEndAlloc(alloc, 1024 * 1024);
    defer alloc.free(data);

    // Load into SDL GPU
    return try sdlerr(c.SDL_CreateGPUShader(device, &.{
        .code_size = data.len,
        .code = data.ptr,
        .entrypoint = "main",
        .format = c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = @intFromEnum(stage),
        .num_samplers = 0,
        .num_storage_textures = 0,
        .num_storage_buffers = 0,
        .num_uniform_buffers = 0,
        .props = 0,
    }));
}
