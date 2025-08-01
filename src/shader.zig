const std = @import("std");
const options = @import("options");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const root = @import("root");
const sdlerr = root.sdlerr;
const c = root.c;

const log = std.log.scoped(.shader);

pub const Stage = enum(c_uint) {
    vert = c.SDL_GPU_SHADERSTAGE_VERTEX,
    frag = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
};

pub fn stageFromExtension(name: []const u8) !Stage {
    const extension = std.fs.path.extension(name);
    if (extension.len == 0) return error.NoStageExtension;
    return std.meta.stringToEnum(Stage, extension[1..]) orelse error.NoStageExtension;
}

pub fn loadShader(alloc: Allocator, device: *c.SDL_GPUDevice, name: []const u8) !*c.SDL_GPUShader {
    if (options.use_shaderc) {
        return loadShaderGlsl(alloc, device, name);
    } else {
        return loadShaderSpirv(alloc, device, name);
    }
}

fn loadShaderSpirv(alloc: Allocator, device: *c.SDL_GPUDevice, name: []const u8) !*c.SDL_GPUShader {
    // Determine shader stage from extension
    const stage = try stageFromExtension(name);

    // Allocate relative path to SPIR-V file
    const spirv_name = try std.mem.concat(alloc, u8, &[_][]const u8{ name, ".spv" });
    defer alloc.free(spirv_name);

    // Load SPIR-V binary
    // const file = try std.fs.cwd().openFile(try util.dataFilePath(name), .{});
    // defer file.close();
    // const data = try file.readToEndAlloc(alloc, 1024 * 1024);
    const data = try util.loadFileZ(alloc, try util.dataFilePath(spirv_name));
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

fn loadShaderGlsl(alloc: Allocator, device: *c.SDL_GPUDevice, name: []const u8) !*c.SDL_GPUShader {
    const shaderc = @import("shader_compiler.zig");

    // Determine shader stage from extension
    const stage = try stageFromExtension(name);

    // Allocate full file path
    const path = try util.shaderFilePath(name);

    // Read file and compile to SPIR-V
    const glsl = try util.loadFileZ(alloc, path);
    defer alloc.free(glsl);
    const data = shaderc.compileShader(alloc, glsl, path) catch |err| {
        log.err("{s}\n", .{shaderc.shader_err.load()});
        return err;
    };
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
