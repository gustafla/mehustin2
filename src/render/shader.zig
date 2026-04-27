const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c");
const engine = @import("engine");
const types = engine.types;
const resource = engine.resource;
const sdlerr = engine.err.sdlerr;
const schema = engine.schema;

const Error = error{SdlError} || resource.Error;

pub fn fileName(
    allocator: Allocator,
    stage: []const u8,
    shader: schema.Shader,
) Allocator.Error![]const u8 {
    return try std.mem.concat(
        allocator,
        u8,
        &.{ shader.file, ".", stage, ".", shader.entrypoint, ".spv" },
    );
}

pub fn loadShader(
    io: std.Io,
    arena: Allocator,
    device: *c.SDL_GPUDevice,
    stage: types.ShaderStage,
    shader: schema.Shader,
    info: anytype,
) Error!*c.SDL_GPUShader {
    // Allocate SPIR-V file name
    const spirv_name = try fileName(arena, @tagName(stage), shader);

    // Load SPIR-V binary
    const path = try resource.dataFilePath(arena, spirv_name);
    const data = try resource.loadFileZ(io, arena, path);

    var create_info = std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, info);
    create_info.code_size = data.len;
    create_info.code = data.ptr;
    create_info.entrypoint = "main"; // GLSL entry point name must be "main"
    create_info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    create_info.stage = @intFromEnum(stage);

    return sdlerr(c.SDL_CreateGPUShader(device, &create_info));
}
