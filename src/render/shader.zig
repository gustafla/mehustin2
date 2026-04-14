const std = @import("std");
const Allocator = std.mem.Allocator;

const engine = @import("engine");
const resource = engine.resource;
const c = engine.c;
const sdlerr = engine.err.sdlerr;

pub const Stage = enum(c_uint) {
    vert = c.SDL_GPU_SHADERSTAGE_VERTEX,
    frag = c.SDL_GPU_SHADERSTAGE_FRAGMENT,

    pub fn fromExtension(name: []const u8) !@This() {
        const extension = std.fs.path.extension(name);
        if (extension.len == 0) return error.NoStageExtension;
        return std.meta.stringToEnum(Stage, extension[1..]) orelse error.NoStageExtension;
    }
};

fn createShader(device: *c.SDL_GPUDevice, data: []const u8, stage: Stage, info: anytype) !*c.SDL_GPUShader {
    var create_info = std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, info);
    create_info.code_size = data.len;
    create_info.code = data.ptr;
    create_info.entrypoint = "main"; // TODO: Remove this
    create_info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    create_info.stage = @intFromEnum(stage);

    return sdlerr(c.SDL_CreateGPUShader(device, &create_info));
}

pub fn loadSpirv(gpa: Allocator, name: []const u8) ![:0]const u8 {
    // Allocate relative path to SPIR-V file
    const spirv_name = try std.mem.concat(gpa, u8, &.{ name, ".spv" });
    defer gpa.free(spirv_name);

    // Load SPIR-V binary
    const path = try resource.dataFilePath(gpa, spirv_name);
    defer gpa.free(path);
    const data = try resource.loadFileZ(gpa, path);

    return data;
}

pub fn loadShader(gpa: Allocator, device: *c.SDL_GPUDevice, name: []const u8, info: anytype) !*c.SDL_GPUShader {
    const stage = try Stage.fromExtension(name);
    const data = try loadSpirv(gpa, name);
    defer gpa.free(data);
    return createShader(device, data, stage, info);
}
