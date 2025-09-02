const std = @import("std");
const res = @import("res.zig");
const Allocator = std.mem.Allocator;
const root = @import("root");
const sdlerr = @import("err.zig").sdlerr;
const c = @import("render.zig").c;

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

pub fn loadShader(alloc: Allocator, device: *c.SDL_GPUDevice, name: []const u8, info: anytype) !*c.SDL_GPUShader {
    return loadShaderSpirv(alloc, device, name, info);
}

fn createShader(device: *c.SDL_GPUDevice, data: []u8, stage: Stage, info: anytype) !*c.SDL_GPUShader {
    var create_info = std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, info);
    create_info.code_size = data.len;
    create_info.code = data.ptr;
    create_info.entrypoint = "main";
    create_info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    create_info.stage = @intFromEnum(stage);

    return sdlerr(c.SDL_CreateGPUShader(device, &create_info));
}

fn loadShaderSpirv(alloc: Allocator, device: *c.SDL_GPUDevice, name: []const u8, info: anytype) !*c.SDL_GPUShader {
    // Determine shader stage from extension
    const stage = try stageFromExtension(name);

    // Allocate relative path to SPIR-V file
    const spirv_name = try std.mem.concat(alloc, u8, &.{ name, ".spv" });
    defer alloc.free(spirv_name);

    // Load SPIR-V binary
    const data = try res.loadFileZ(alloc, try res.dataFilePath(spirv_name));
    defer alloc.free(data);

    // Load into SDL GPU
    return createShader(device, data, stage, info);
}
