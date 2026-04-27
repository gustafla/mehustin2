const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c");
const engine = @import("engine");
const types = engine.types;
const resource = engine.resource;
const sdlerr = engine.err.sdlerr;
const schema = engine.schema;
const Shader = schema.Shader;

const Error = error{SdlError} || resource.Error;

pub fn loadShader(
    io: std.Io,
    arena: Allocator,
    device: *c.SDL_GPUDevice,
    comptime stage: Shader.Stage,
    shader: Shader,
    info: anytype,
) Error!*c.SDL_GPUShader {
    // Allocate SPIR-V file name
    const spirv_name = try shader.spvFilename(arena, stage, null);

    // Load SPIR-V binary
    const path = try resource.dataFilePath(arena, spirv_name);
    const data = try resource.loadFileZ(io, arena, path);

    var create_info = std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, info);
    create_info.code_size = data.len;
    create_info.code = data.ptr;
    create_info.entrypoint = "main"; // GLSL entry point name must be "main"
    create_info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    create_info.stage = @intFromEnum(@field(types.ShaderStage, @tagName(stage)));

    return sdlerr(c.SDL_CreateGPUShader(device, &create_info));
}
