const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const config: Config = @import("render.zon");
const main_config = @import("config.zon");

const font = @import("font.zig");
const math = @import("math.zig");
const noise = @import("noise.zig");
const resource = @import("resource.zig");
const sdlerr = @import("err.zig").sdlerr;
const shader = @import("shader.zig");

pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("stb_image.h");
    @cInclude("stb_truetype.h");
});

const VertexFormat = enum(c.SDL_GPUVertexElementFormat) {
    Float = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT,
    Vec2 = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
    Vec3 = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
    Vec4 = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,

    fn len(self: @This()) u32 {
        return switch (self) {
            .Float => @sizeOf(f32),
            .Vec2 => @sizeOf(f32) * 2,
            .Vec3 => @sizeOf(f32) * 3,
            .Vec4 => @sizeOf(f32) * 4,
        };
    }

    fn toSDL(self: @This()) c.SDL_GPUVertexElementFormat {
        return @intFromEnum(self);
    }
};

const VertexAttributes = packed struct {
    coords: bool = false,
    normals: bool = false,
    colors: bool = false,
    uvs: bool = false,
};

fn attribParameters(comptime attrib_name: []const u8) struct {
    pitch: u32,
    format: c.SDL_GPUVertexElementFormat,
} {
    const field = std.meta.stringToEnum(std.meta.FieldEnum(VertexAttributes), attrib_name);
    return switch (field orelse @panic("parameters not found for attrib name")) {
        .coords => .{ .pitch = @sizeOf(f32) * 3, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3 },
        .normals => .{ .pitch = @sizeOf(f32) * 3, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3 },
        .colors => .{ .pitch = @sizeOf(f32) * 3, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3 },
        .uvs => .{ .pitch = @sizeOf(f32) * 2, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2 },
    };
}

const VertexData = struct {
    coords: []const f32,
    normals: []const f32 = &.{},
    colors: []const f32 = &.{},
    uvs: []const f32 = &.{},
};

const VertexBuffers = struct {
    coords: ?*c.SDL_GPUBuffer,
    normals: ?*c.SDL_GPUBuffer,
    colors: ?*c.SDL_GPUBuffer,
    uvs: ?*c.SDL_GPUBuffer,
};

// Statically assert that structs above have matching fields
comptime {
    const attributes_fields = @typeInfo(VertexAttributes).@"struct".fields;
    const data_fields = @typeInfo(VertexData).@"struct".fields;
    const buffers_fields = @typeInfo(VertexBuffers).@"struct".fields;
    for (attributes_fields, data_fields, buffers_fields) |a, d, b| {
        std.debug.assert(std.mem.eql(u8, a.name, d.name));
        std.debug.assert(std.mem.eql(u8, a.name, b.name));
    }
}

const ColorFormat = enum(c.SDL_GPUTextureFormat) {
    Default = 0,
    R8Unorm = c.SDL_GPU_TEXTUREFORMAT_R8_UNORM,
    R8g8b8a8Unorm = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
    R16g16b16a16Float = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
    R11g11b10Float = c.SDL_GPU_TEXTUREFORMAT_R11G11B10_UFLOAT,
    Swapchain,

    fn toSDL(self: ColorFormat) c.SDL_GPUTextureFormat {
        return switch (self) {
            .Default => c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
            .Swapchain => c.SDL_GetGPUSwapchainTextureFormat(
                device,
                window,
            ),
            else => @intFromEnum(self),
        };
    }
};

const DepthFormat = enum(c.SDL_GPUTextureFormat) {
    D16Unorm = c.SDL_GPU_TEXTUREFORMAT_D16_UNORM,
    D24Unorm = c.SDL_GPU_TEXTUREFORMAT_D24_UNORM,
    D32Float = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
};

const PrimitiveType = enum(c.SDL_GPUPrimitiveType) {
    TriangleList = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
    TriangleStrip = c.SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP,
    LineList = c.SDL_GPU_PRIMITIVETYPE_LINELIST,
    LineStrip = c.SDL_GPU_PRIMITIVETYPE_LINESTRIP,
    PointList = c.SDL_GPU_PRIMITIVETYPE_POINTLIST,
};

const CompareOp = enum(c.SDL_GPUCompareOp) {
    Less = c.SDL_GPU_COMPAREOP_LESS,
    LessOrEqual = c.SDL_GPU_COMPAREOP_LESS_OR_EQUAL,
};

const UniformData = enum {
    Matrices,
    Shadertoy,
};

const ColorTarget = union(enum) {
    index: usize,
    swapchain,
};

const Pipeline = struct {
    vert: []const u8 = "tri.vert",
    frag: []const u8,
    vertex_attributes: VertexAttributes = .{},
    instance_attributes: []const VertexFormat = &.{},
    primitive_type: PrimitiveType = .TriangleStrip,
    depth_test: ?struct {
        compare_op: CompareOp = .LessOrEqual,
        enable: bool = true,
        write: bool = true,
    } = null,
};

const Texture = union(enum) {
    color: usize,
    depth: usize,
    font: usize,
    image: []const u8,
    simplex2,
};

const DrawNum = union(enum) {
    infer,
    num: u32,
};

const Pass = struct {
    drawcalls: []const struct {
        pipeline: Pipeline,
        vertices: ?usize = null,
        instances: ?usize = null,
        vertex_samplers: []const Texture = &.{},
        fragment_samplers: []const Texture = &.{},
        vertex_uniforms: []const UniformData = &.{},
        fragment_uniforms: []const UniformData = &.{},
        num_vertices: DrawNum = .infer,
        num_instances: DrawNum = .infer,
        first_vertex: u32 = 0,
        first_instance: u32 = 0,
    },
    color_targets: []const ColorTarget = &.{.swapchain},
    depth_target: ?usize = null,
};

const Text = struct {
    str: []const u8,
    font: usize = 0,
};

const VertexSource = union(enum) {
    static: VertexData,
};

const InstanceSource = union(enum) {
    text: Text,
};

const Font = struct {
    ttf: []const u8,
    size: f32,
    padding: u32 = 5,
    dist_scale: f32 = 32,
    atlas_width: u32 = 1024,
    atlas_height: u32 = 1024,
};

const Config = struct {
    color_textures: []const ColorFormat = &.{},
    depth_textures: []const DepthFormat = &.{},
    vertices: []const VertexSource,
    instances: []const InstanceSource,
    fonts: []const Font,
    passes: []const Pass,
    noise_size: u32 = 256,
    noise_scale: f32 = 0.5,
};

// Compute upper bounds from config
fn maxSliceLen(parent: anytype, comptime fields: []const []const u8) usize {
    if (fields.len == 0) {
        return parent.len;
    }

    var max: usize = 0;

    switch (@typeInfo(@TypeOf(parent))) {
        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    for (parent) |elem| {
                        const len = maxSliceLen(elem, fields);
                        max = @max(max, len);
                    }
                },
                else => @compileError("Pointer chasing is not implemented"),
            }
        },
        .@"struct" => {
            max = maxSliceLen(@field(parent, fields[0]), fields[1..]);
        },
        else => |t| @compileError("Only structs and slices implemented. Encountered: " ++ @typeName(@TypeOf(t))),
    }

    return max;
}

const max_pass_color_targets = maxSliceLen(config.passes, &.{"color_targets"});
const max_instance_attributes = maxSliceLen(config.passes, &.{ "drawcalls", "pipeline", "instance_attributes" });

const ShaderInfo = struct {
    num_samplers: u32,
    num_storage_textures: u32 = 0,
    num_storage_buffers: u32 = 0,
    num_uniform_buffers: u32,
};

const PipelineKey = struct {
    pipeline: Pipeline,
    vert_info: ShaderInfo,
    frag_info: ShaderInfo,
    color_targets_buf: [max_pass_color_targets]ColorFormat,
    num_color_targets: u32,
    depth_target: ?DepthFormat,
};

// Generate a comptime array of all unique pipeline keys from config
const pipeline_keys = init: {
    // Find upper bound for pipelines defined in render config
    var n = 0;
    for (config.passes) |pass| {
        n += pass.drawcalls.len;
    }

    // Initialize unique map keys with O(n^2) filtering
    var keys: [n]PipelineKey = undefined;
    var num_keys = 0;
    for (config.passes) |pass| {
        var color_targets = std.mem.zeroes([pass.color_targets.len]ColorFormat);
        for (pass.color_targets, color_targets[0..pass.color_targets.len]) |format, *target| {
            target.* = switch (format) {
                .index => |i| config.color_textures[i],
                .swapchain => .Swapchain,
            };
        }
        outer: for (pass.drawcalls) |drawcall| {
            const candidate: PipelineKey = .{
                .pipeline = drawcall.pipeline,
                .vert_info = .{
                    .num_samplers = drawcall.vertex_samplers.len,
                    .num_uniform_buffers = drawcall.vertex_uniforms.len,
                },
                .frag_info = .{
                    .num_samplers = drawcall.fragment_samplers.len,
                    .num_uniform_buffers = drawcall.fragment_uniforms.len,
                },
                .color_targets_buf = color_targets,
                .num_color_targets = pass.color_targets.len,
                .depth_target = if (pass.depth_target) |i| config.depth_textures[i] else null,
            };
            for (keys[0..num_keys]) |key| {
                if (std.meta.eql(key, candidate)) {
                    continue :outer;
                }
            }
            keys[num_keys] = candidate;
            num_keys += 1;
        }
    }

    break :init keys[0..num_keys].*;
};

// Generate a comptime array of all unique image samplers
const image_keys = init: {
    // Find upper bound for images defined in render config
    var n = 0;
    for (config.passes) |pass| {
        for (pass.drawcalls) |drawcall| {
            n += drawcall.vertex_samplers.len;
            n += drawcall.fragment_samplers.len;
        }
    }

    // Initialize unique map keys with O(n^2) filtering
    var keys: [n][]const u8 = undefined;
    var num_keys = 0;
    for (config.passes) |pass| {
        for (pass.drawcalls) |drawcall| {
            for (.{
                drawcall.vertex_samplers,
                drawcall.fragment_samplers,
            }) |samplers| {
                outer: for (samplers) |sampler| {
                    switch (sampler) {
                        .image => |name| {
                            for (keys[0..num_keys]) |key| {
                                if (std.mem.eql(u8, name, key)) {
                                    continue :outer;
                                }
                            }
                            keys[num_keys] = name;
                            num_keys += 1;
                        },
                        else => {},
                    }
                }
            }
        }
    }

    break :init keys[0..num_keys].*;
};

const render_width: f32 = @floatFromInt(main_config.width);
const render_height: f32 = @floatFromInt(main_config.height);
const render_aspect = render_width / render_height;

// TODO: https://github.com/ziglang/zig/issues/25026
// var debug_allocator: std.heap.DebugAllocator(.{}) = undefined;
var gpa: Allocator = undefined;
var window: *c.SDL_Window = undefined;
var device: *c.SDL_GPUDevice = undefined;
var nearest: *c.SDL_GPUSampler = undefined;
var output_buffer: *c.SDL_GPUTexture = undefined;
var pipelines: [pipeline_keys.len]*c.SDL_GPUGraphicsPipeline = undefined;
var font_textures: [config.fonts.len]*c.SDL_GPUTexture = undefined;
var image_textures: [image_keys.len]*c.SDL_GPUTexture = undefined;
var color_textures: [config.color_textures.len]*c.SDL_GPUTexture = undefined;
var depth_textures: [config.depth_textures.len]*c.SDL_GPUTexture = undefined;
var noise_transfer: *c.SDL_GPUTransferBuffer = undefined;
var noise_texture: *c.SDL_GPUTexture = undefined;
var vertex_buffers: [config.vertices.len]VertexBuffers = undefined;
var instance_buffers: [config.instances.len]*c.SDL_GPUBuffer = undefined;
var vertex_counts: [config.vertices.len]u32 = undefined;
var instance_counts: [config.instances.len]u32 = undefined;

pub fn deinit() void {
    for (vertex_buffers) |buf| {
        inline for (@typeInfo(VertexBuffers).@"struct".fields) |field| {
            c.SDL_ReleaseGPUBuffer(device, @field(buf, field.name));
        }
    }
    c.SDL_ReleaseGPUTexture(device, noise_texture);
    c.SDL_ReleaseGPUTransferBuffer(device, noise_transfer);
    for (depth_textures) |texture| {
        c.SDL_ReleaseGPUTexture(device, texture);
    }
    for (color_textures) |texture| {
        c.SDL_ReleaseGPUTexture(device, texture);
    }
    for (image_textures) |texture| {
        c.SDL_ReleaseGPUTexture(device, texture);
    }
    for (pipelines) |pipeline| {
        c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    }
    c.SDL_ReleaseGPUTexture(device, output_buffer);
    c.SDL_ReleaseGPUSampler(device, nearest);
    for (font_textures) |texture| {
        c.SDL_ReleaseGPUTexture(device, texture);
    }
    for (instance_buffers) |buffer| {
        c.SDL_ReleaseGPUBuffer(device, buffer);
    }

    // TODO: https://github.com/ziglang/zig/issues/25026
    // if (builtin.mode == .Debug) {
    //     _ = debug_allocator.detectLeaks();
    // }
}

fn initText(
    str: []const u8,
    size: f32,
    buffer: **c.SDL_GPUBuffer,
    glyphs: *[128]font.GlyphInfo,
) !u32 {
    const Instance = extern struct {
        uv_rect: [4]f32,
        pos_rect: [4]f32,
        color: [4]f32,
    };
    const buf = try gpa.alloc(Instance, str.len);
    defer gpa.free(buf);

    @memset(buf, std.mem.zeroes(Instance));

    var x: f32 = 0;
    var y: f32 = size;
    var instances: u32 = 0;

    for (str) |char| {
        const g = glyphs[char];

        if (char == '\n') {
            y += size;
            x = 0;
            continue;
        }

        if (char == ' ') {
            x += size / 2;
            continue;
        }

        const p_min_x = x + g.x_off;
        const p_min_y = y + g.y_off;

        buf[instances] = .{
            .uv_rect = .{ g.uv_min[0], g.uv_min[1], g.uv_max[0], g.uv_max[1] },
            .pos_rect = .{
                p_min_x,
                p_min_y,
                p_min_x + g.width,
                p_min_y + g.height,
            },
            .color = @splat(1),
        };

        x += g.advance;
        instances += 1;
    }

    buffer.* = try initBuffer(Instance, buf, c.SDL_GPU_BUFFERUSAGE_VERTEX);
    return instances;
}

fn initFont(
    name: []const u8,
    font_size: f32,
    padding: u32,
    dist_scale: f32,
    width: u32,
    height: u32,
    glyph_data: *[128]font.GlyphInfo,
) !*c.SDL_GPUTexture {
    const path = try resource.dataFilePath(gpa, name);
    defer gpa.free(path);
    const ttf = try resource.loadFileZ(gpa, path);
    defer gpa.free(ttf);

    const texture = try sdlerr(c.SDL_CreateGPUTexture(device, &.{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = @intCast(width),
        .height = @intCast(height),
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }));
    errdefer c.SDL_ReleaseGPUTexture(device, texture);

    const transfer_buffer = try sdlerr(c.SDL_CreateGPUTransferBuffer(device, &.{
        .size = @intCast(width * height),
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
    }));
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);
    const atlas: [*]u8 = @ptrCast(@alignCast(try sdlerr(c.SDL_MapGPUTransferBuffer(
        device,
        transfer_buffer,
        false,
    ))));

    try font.bakeSDFAtlas(
        ttf.ptr,
        font_size,
        padding,
        dist_scale,
        width,
        height,
        glyph_data,
        atlas,
    );

    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    const cmdbuf = c.SDL_AcquireGPUCommandBuffer(device);
    const copy_pass = c.SDL_BeginGPUCopyPass(cmdbuf);
    c.SDL_UploadToGPUTexture(
        copy_pass,
        &.{
            .offset = 0,
            .transfer_buffer = transfer_buffer,
        },
        &.{
            .texture = texture,
            .w = @intCast(width),
            .h = @intCast(height),
            .d = 1,
        },
        false,
    );
    c.SDL_EndGPUCopyPass(copy_pass);
    try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));

    return texture;
}

fn initImageTexture(name: []const u8) !*c.SDL_GPUTexture {
    var width: c_int = 0;
    var height: c_int = 0;
    var n: c_int = 0;

    const path = try resource.dataFilePath(gpa, name);
    defer gpa.free(path);
    const data: [*]u8 = c.stbi_load(path, &width, &height, &n, 4) orelse
        return error.ImageLoadFailed;
    defer c.stbi_image_free(data);
    const size: usize = @intCast(width * height * 4);

    const texture = try sdlerr(c.SDL_CreateGPUTexture(device, &.{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        .width = @intCast(width),
        .height = @intCast(height),
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }));
    errdefer c.SDL_ReleaseGPUTexture(device, texture);

    const transfer_buffer = try sdlerr(c.SDL_CreateGPUTransferBuffer(device, &.{
        .size = @intCast(size),
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
    }));
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);
    const tbp: [*]u8 = @ptrCast(@alignCast(try sdlerr(c.SDL_MapGPUTransferBuffer(
        device,
        transfer_buffer,
        false,
    ))));
    @memcpy(tbp, data[0..size]);
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    const cmdbuf = c.SDL_AcquireGPUCommandBuffer(device);
    const copy_pass = c.SDL_BeginGPUCopyPass(cmdbuf);
    c.SDL_UploadToGPUTexture(
        copy_pass,
        &.{
            .offset = 0,
            .transfer_buffer = transfer_buffer,
        },
        &.{
            .texture = texture,
            .w = @intCast(width),
            .h = @intCast(height),
            .d = 1,
        },
        false,
    );
    c.SDL_EndGPUCopyPass(copy_pass);
    try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));

    return texture;
}

fn initColorTexture(
    format: ColorFormat,
    wh: struct { width: u32 = render_width, height: u32 = render_height },
) !*c.SDL_GPUTexture {
    return try sdlerr(c.SDL_CreateGPUTexture(device, &.{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = switch (format) {
            .Swapchain => c.SDL_GetGPUSwapchainTextureFormat(
                device,
                window,
            ),
            else => @intFromEnum(format),
        },
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
        .width = wh.width,
        .height = wh.height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }));
}

fn initDepthTexture(
    format: DepthFormat,
    wh: struct { width: u32 = render_width, height: u32 = render_height },
) !*c.SDL_GPUTexture {
    return try sdlerr(c.SDL_CreateGPUTexture(device, &.{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = @intFromEnum(format),
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
        .width = wh.width,
        .height = wh.height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }));
}

fn initPipeline(key: PipelineKey) !*c.SDL_GPUGraphicsPipeline {
    const pipeline = key.pipeline;
    const vert = try shader.loadShader(gpa, device, pipeline.vert, key.vert_info);
    defer c.SDL_ReleaseGPUShader(device, vert);
    const frag = try shader.loadShader(gpa, device, pipeline.frag, key.frag_info);
    defer c.SDL_ReleaseGPUShader(device, frag);

    var color_targets: [max_pass_color_targets]c.SDL_GPUColorTargetDescription = undefined;
    for (
        key.color_targets_buf[0..key.num_color_targets],
        color_targets[0..key.num_color_targets],
    ) |target_def, *target| {
        const format = target_def.toSDL();
        target.* = .{ .format = format };
    }

    // First 0..va_locations vertex input locations are for VertexAttributes,
    // i.e. 0 = coords, 1 = normals, ...
    // Each vertex attribute is read from separate buffers.
    const va_locations = @bitSizeOf(VertexAttributes);
    const max_attribs = va_locations + max_instance_attributes;
    var buffers: [max_attribs]c.SDL_GPUVertexBufferDescription = undefined;
    var attribs: [max_attribs]c.SDL_GPUVertexAttribute = undefined;
    var num_buffers: u32 = 0;
    var num_attribs: u32 = 0;
    inline for (@typeInfo(VertexAttributes).@"struct".fields, 0..) |field, location| {
        const param = attribParameters(field.name);
        const enabled = @field(pipeline.vertex_attributes, field.name);
        if (enabled) {
            buffers[num_buffers] = .{
                .slot = num_buffers,
                .pitch = param.pitch,
                .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                .instance_step_rate = 0,
            };
            attribs[num_attribs] = .{
                .location = @intCast(location),
                .buffer_slot = num_buffers,
                .format = param.format,
                .offset = 0,
            };
            num_buffers += 1;
            num_attribs += 1;
        }
    }

    // Subsequent va_locations.. vertex input locations are for instance attributes.
    // Only one instance buffer with interleaved attributes is supported.
    if (pipeline.instance_attributes.len > 0) {
        var instance_attrib_offset: u32 = 0;
        for (pipeline.instance_attributes, va_locations..) |attrib, location| {
            attribs[num_attribs] = .{
                .location = @intCast(location),
                .buffer_slot = num_buffers,
                .format = attrib.toSDL(),
                .offset = instance_attrib_offset,
            };
            instance_attrib_offset += attrib.len();
            num_attribs += 1;
        }
        buffers[num_buffers] = .{
            .slot = num_buffers,
            .pitch = instance_attrib_offset,
            .input_rate = c.SDL_GPU_VERTEXINPUTRATE_INSTANCE,
            .instance_step_rate = 0,
        };
        num_buffers += 1;
    }

    return try sdlerr(c.SDL_CreateGPUGraphicsPipeline(device, &.{
        .vertex_shader = vert,
        .fragment_shader = frag,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &buffers,
            .num_vertex_buffers = num_buffers,
            .vertex_attributes = &attribs,
            .num_vertex_attributes = num_attribs,
        },
        .primitive_type = @intFromEnum(pipeline.primitive_type),
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_BACK,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
        },
        .multisample_state = .{
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        },
        .depth_stencil_state = if (pipeline.depth_test) |state| .{
            .compare_op = @intFromEnum(state.compare_op),
            .enable_depth_test = state.enable,
            .enable_depth_write = state.write,
            .enable_stencil_test = false,
        } else .{
            .enable_depth_test = false,
            .enable_depth_write = false,
            .enable_stencil_test = false,
        },
        .target_info = .{
            .num_color_targets = key.num_color_targets,
            .color_target_descriptions = &color_targets,
            .depth_stencil_format = @intFromEnum(key.depth_target orelse undefined),
            .has_depth_stencil_target = key.depth_target != null,
        },
        .props = 0,
    }));
}

fn initBuffer(T: type, data: []const T, usage: c.SDL_GPUBufferUsageFlags) !*c.SDL_GPUBuffer {
    const size: u32 = @intCast(data.len * @sizeOf(T));

    const buffer = try sdlerr(c.SDL_CreateGPUBuffer(
        device,
        &.{
            .size = size,
            .usage = usage,
            .props = 0,
        },
    ));

    const transferbuf = try sdlerr(c.SDL_CreateGPUTransferBuffer(
        device,
        &.{
            .size = size,
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .props = 0,
        },
    ));
    defer c.SDL_ReleaseGPUTransferBuffer(device, transferbuf);
    const tbp: [*]T = @ptrCast(@alignCast(try sdlerr(c.SDL_MapGPUTransferBuffer(
        device,
        transferbuf,
        false,
    ))));
    @memcpy(tbp, data);
    c.SDL_UnmapGPUTransferBuffer(device, transferbuf);

    const cmdbuf = c.SDL_AcquireGPUCommandBuffer(device);
    const copy_pass = c.SDL_BeginGPUCopyPass(cmdbuf);
    c.SDL_UploadToGPUBuffer(
        copy_pass,
        &.{
            .offset = 0,
            .transfer_buffer = transferbuf,
        },
        &.{
            .size = size,
            .offset = 0,
            .buffer = buffer,
        },
        false,
    );
    c.SDL_EndGPUCopyPass(copy_pass);
    try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));
    return buffer;
}

pub fn init(win: *c.SDL_Window, dev: *c.SDL_GPUDevice) !void {
    // Initialize allocator
    gpa =
        // TODO: https://github.com/ziglang/zig/issues/25026
        // if (builtin.mode == .Debug) blk: {
        //     debug_allocator = std.heap.DebugAllocator(.{}).init;
        //     break :blk debug_allocator.allocator();
        // } else
        std.heap.c_allocator;

    window = win;
    device = dev;

    nearest = try sdlerr(c.SDL_CreateGPUSampler(device, &std.mem.zeroInit(
        c.SDL_GPUSamplerCreateInfo,
        .{
            .min_filter = c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = c.SDL_GPU_FILTER_NEAREST,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_MIRRORED_REPEAT,
            // .max_lod =
        },
    )));
    errdefer c.SDL_ReleaseGPUSampler(device, nearest);

    output_buffer = try initColorTexture(.Swapchain, .{});
    errdefer c.SDL_ReleaseGPUTexture(device, output_buffer);

    for (image_keys, &image_textures) |name, *texture| {
        texture.* = try initImageTexture(name);
        errdefer c.SDL_ReleaseGPUTexture(texture.*);
    }

    for (config.color_textures, &color_textures) |format, *texture| {
        texture.* = try initColorTexture(format, .{});
        errdefer c.SDL_ReleaseGPUTexture(texture.*);
    }

    for (config.depth_textures, &depth_textures) |format, *texture| {
        texture.* = try initDepthTexture(format, .{});
        errdefer c.SDL_ReleaseGPUTexture(texture.*);
    }

    noise_transfer = try sdlerr(c.SDL_CreateGPUTransferBuffer(device, &.{
        .size = @intCast(config.noise_size * config.noise_size),
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
    }));
    noise_texture = try initColorTexture(
        .R8Unorm,
        .{ .width = config.noise_size, .height = config.noise_size },
    );

    for (pipeline_keys, &pipelines) |key, *pipeline| {
        pipeline.* = try initPipeline(key);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline.*);
    }

    for (config.vertices, &vertex_buffers, &vertex_counts) |def, *buffers, *count| {
        const data = def.static;
        // Create vertex buffer for each vertex data slice (matching names)
        inline for (@typeInfo(VertexData).@"struct".fields) |field| {
            @field(buffers.*, field.name) = if (@field(data, field.name).len > 0)
                try initBuffer(f32, @field(data, field.name), c.SDL_GPU_BUFFERUSAGE_VERTEX)
            else
                null;
            errdefer c.SDL_ReleaseGPUBuffer(device, @field(buffers.*, field.name));
        }
        // Divide by three because XYZ
        count.* = @intCast(data.coords.len / 3);
    }

    var font_glyph_data: [config.fonts.len][128]font.GlyphInfo = undefined;
    for (config.fonts, &font_textures, &font_glyph_data) |def, *texture, *glyph_data| {
        texture.* = try initFont(
            def.ttf,
            def.size,
            def.padding,
            def.dist_scale,
            def.atlas_width,
            def.atlas_height,
            glyph_data,
        );
    }

    for (config.instances, &instance_buffers, &instance_counts) |def, *buffer, *count| {
        const text = def.text;
        const size = config.fonts[text.font].size;
        const glyphs = &font_glyph_data[text.font];
        count.* = try initText(text.str, size, buffer, glyphs);
    }
}

pub fn render(time: f32) !void {
    // Acquire command buffer
    const cmdbuf = try sdlerr(c.SDL_AcquireGPUCommandBuffer(device));
    errdefer _ = c.SDL_CancelGPUCommandBuffer(cmdbuf);

    // Acquire swapchain texture
    var width: u32 = 0;
    var height: u32 = 0;
    const swapchain_texture = blk: {
        var swapchain_texture: ?*c.SDL_GPUTexture = undefined;
        try sdlerr(c.SDL_WaitAndAcquireGPUSwapchainTexture(
            cmdbuf,
            window,
            &swapchain_texture,
            &width,
            &height,
        ));
        break :blk swapchain_texture orelse {
            try sdlerr(c.SDL_CancelGPUCommandBuffer(cmdbuf));
            return;
        };
    };
    const resolution_match =
        (width == main_config.width and height >= main_config.height) or
        (height == main_config.height and width >= main_config.width);

    // Compute viewport preserving aspect ratio rendering to swapchain
    const swapchain_viewport = viewport(width, height);

    // Compute view & projection matrices
    const matrices: extern struct {
        projection: math.Mat4,
        view: math.Mat4,
    } = .{
        .projection = math.Mat4.perspective(
            math.radians(90),
            render_aspect,
            1,
            4096,
        ),
        .view = math.Mat4.lookAt(
            if (time > 14) .{
                @sin((time - 14) / 4 * std.math.pi) * 3,
                @sin((time - 14) / 8 * std.math.pi) * 2,
                @cos(time / 3 * std.math.pi) * 4,
            } else .{ 0, 0, 4 },
            math.vec3.ZERO,
            math.vec3.YUP,
        ),
    };

    // Initialize uniforms
    const uniforms: extern struct {
        resolution: [2]f32,
        time: f32,
    } = .{
        .resolution = .{ render_width, render_height },
        .time = time,
    };

    // Compute noise texture
    const nd: [*]u8 = @ptrCast(@alignCast(try sdlerr(c.SDL_MapGPUTransferBuffer(
        device,
        noise_transfer,
        true,
    ))));
    for (0..config.noise_size) |y| {
        for (0..config.noise_size) |x| {
            const scale = config.noise_scale;
            const hash = std.hash.int(@as(u32, @bitCast(time)));
            const noise_val = noise.simplex2(
                (@as(f32, @floatFromInt(x)) * scale) + @as(f32, @floatFromInt(hash & 0x7fff)),
                (@as(f32, @floatFromInt(y)) * scale),
            );
            nd[y * config.noise_size + x] =
                @intFromFloat((noise_val * 0.5 + 0.5) * 256);
        }
    }
    c.SDL_UnmapGPUTransferBuffer(device, noise_transfer);
    const copy_pass = c.SDL_BeginGPUCopyPass(cmdbuf);
    c.SDL_UploadToGPUTexture(copy_pass, &.{
        .offset = 0,
        .transfer_buffer = noise_transfer,
    }, &.{
        .texture = noise_texture,
        .w = config.noise_size,
        .h = config.noise_size,
        .d = 1,
    }, true);
    c.SDL_EndGPUCopyPass(copy_pass);

    // Render passes
    inline for (config.passes) |pass| {
        // Initialize color target infos
        const color_target_infos = blk: {
            var infos: [pass.color_targets.len]c.SDL_GPUColorTargetInfo = undefined;
            for (pass.color_targets, &infos) |target, *info| {
                info.* = .{
                    .texture = switch (target) {
                        .index => |index| color_textures[index],
                        .swapchain => if (resolution_match)
                            swapchain_texture
                        else
                            output_buffer,
                    },
                    .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                    .load_op = c.SDL_GPU_LOADOP_CLEAR,
                    .store_op = c.SDL_GPU_STOREOP_STORE,
                    .cycle = true,
                };
            }
            break :blk infos;
        };

        // Begin render pass
        const render_pass = c.SDL_BeginGPURenderPass(
            cmdbuf,
            &color_target_infos,
            @intCast(pass.color_targets.len),
            if (pass.depth_target) |index| &.{
                .texture = depth_textures[index],
                .clear_depth = 1,
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
                .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
                .cycle = true,
            } else null,
        );

        // Set viewport if necessary
        const target_swapchain = comptime for (pass.color_targets) |target| {
            if (target == .swapchain) break true;
        } else false;
        if (target_swapchain and resolution_match) {
            c.SDL_SetGPUViewport(render_pass, &swapchain_viewport);
        }

        // Construct color target format array for the pipeline key
        const color_targets = comptime init: {
            var targets = std.mem.zeroes([max_pass_color_targets]ColorFormat);
            for (pass.color_targets, targets[0..pass.color_targets.len]) |format, *target| {
                target.* = switch (format) {
                    .index => |i| config.color_textures[i],
                    .swapchain => .Swapchain,
                };
            }
            break :init targets;
        };

        // Record drawcalls
        inline for (pass.drawcalls) |drawcall| {
            // Find matching pipeline index from pipeline_keys at compile time
            const pipeline_index = comptime for (pipeline_keys, 0..) |plk, i| {
                const key: PipelineKey = .{
                    .pipeline = drawcall.pipeline,
                    .vert_info = .{
                        .num_samplers = @intCast(drawcall.vertex_samplers.len),
                        .num_uniform_buffers = @intCast(drawcall.vertex_uniforms.len),
                    },
                    .frag_info = .{
                        .num_samplers = @intCast(drawcall.fragment_samplers.len),
                        .num_uniform_buffers = @intCast(drawcall.fragment_uniforms.len),
                    },
                    .color_targets_buf = color_targets,
                    .num_color_targets = @intCast(pass.color_targets.len),
                    .depth_target = if (pass.depth_target) |j| config.depth_textures[j] else null,
                };
                if (std.meta.eql(plk, key)) {
                    break i;
                }
            } else @compileError("No pipeline key defined for " ++
                drawcall.pipeline.vert ++ " and " ++ drawcall.pipeline.frag);
            c.SDL_BindGPUGraphicsPipeline(render_pass, pipelines[pipeline_index]);

            // Bind vertex buffers
            var buffer_slot: u32 = 0;
            if (drawcall.vertices) |vertices_index| {
                inline for (@typeInfo(VertexBuffers).@"struct".fields) |field| {
                    const buffer = @field(vertex_buffers[vertices_index], field.name);
                    if (buffer) |buf| {
                        c.SDL_BindGPUVertexBuffers(
                            render_pass,
                            buffer_slot,
                            &.{ .buffer = buf, .offset = 0 },
                            1,
                        );
                        buffer_slot += 1;
                    }
                }
            }

            // Bind instance buffers
            if (drawcall.instances) |instances_index| {
                c.SDL_BindGPUVertexBuffers(
                    render_pass,
                    buffer_slot,
                    &.{ .buffer = instance_buffers[instances_index], .offset = 0 },
                    1,
                );
                buffer_slot += 1;
            }

            // Bind textures
            inline for (.{
                .{
                    .bind = c.SDL_BindGPUVertexSamplers,
                    .tex = drawcall.vertex_samplers,
                },
                .{
                    .bind = c.SDL_BindGPUFragmentSamplers,
                    .tex = drawcall.fragment_samplers,
                },
            }) |stage| {
                inline for (stage.tex, 0..) |tex, slot| {
                    stage.bind(render_pass, @intCast(slot), &.{
                        .texture = switch (tex) {
                            .color => |i| color_textures[i],
                            .depth => |i| depth_textures[i],
                            .font => |i| font_textures[i],
                            .image => |name| blk: {
                                const i = comptime for (image_keys, 0..) |key, i| {
                                    if (std.mem.eql(u8, key, name)) {
                                        break i;
                                    }
                                } else @compileError("No image key defined for " ++ name);
                                break :blk image_textures[i];
                            },
                            .simplex2 => noise_texture,
                        },
                        .sampler = nearest,
                    }, 1);
                }
            }

            // Push uniforms
            inline for (.{
                .{
                    .push = c.SDL_PushGPUVertexUniformData,
                    .ufms = drawcall.vertex_uniforms,
                },
                .{
                    .push = c.SDL_PushGPUFragmentUniformData,
                    .ufms = drawcall.fragment_uniforms,
                },
            }) |stage| {
                inline for (stage.ufms, 0..) |ufm, slot| {
                    const param: struct { *const anyopaque, u32 } = switch (ufm) {
                        .Matrices => .{
                            @ptrCast(&matrices),
                            @sizeOf(@TypeOf(matrices)),
                        },
                        .Shadertoy => .{
                            @ptrCast(&uniforms),
                            @sizeOf(@TypeOf(uniforms)),
                        },
                    };
                    stage.push(
                        cmdbuf,
                        @intCast(slot),
                        param[0],
                        param[1],
                    );
                }
            }

            const num_vertices = switch (drawcall.num_vertices) {
                .infer => if (drawcall.vertices) |i| vertex_counts[i] else 3,
                .num => |num| num,
            };
            const num_instances = switch (drawcall.num_instances) {
                .infer => if (drawcall.instances) |i| instance_counts[i] else 1,
                .num => |num| num,
            };
            c.SDL_DrawGPUPrimitives(
                render_pass,
                num_vertices,
                num_instances,
                drawcall.first_vertex,
                drawcall.first_instance,
            );
        }

        c.SDL_EndGPURenderPass(render_pass);
    }

    // Blit output_buffer to swapchain when necessary
    if (!resolution_match) {
        c.SDL_BlitGPUTexture(cmdbuf, &.{
            .source = .{
                .texture = output_buffer,
                .w = main_config.width,
                .h = main_config.height,
            },
            .destination = .{
                .texture = swapchain_texture,
                .x = @intFromFloat(swapchain_viewport.x + 0.5),
                .y = @intFromFloat(swapchain_viewport.y + 0.5),
                .w = @intFromFloat(swapchain_viewport.w + 0.5),
                .h = @intFromFloat(swapchain_viewport.h + 0.5),
            },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
            .flip_mode = c.SDL_FLIP_NONE,
            .filter = c.SDL_GPU_FILTER_NEAREST,
            .cycle = true,
        });
    }

    try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));
}

fn viewport(width: u32, height: u32) c.SDL_GPUViewport {
    const width_f32: f32 = @floatFromInt(width);
    const height_f32: f32 = @floatFromInt(height);
    const aspect_ratio = width_f32 / height_f32;

    var w = width_f32;
    var h = height_f32;
    if (aspect_ratio > render_aspect) {
        w = height_f32 * render_aspect;
    } else {
        h = width_f32 / render_aspect;
    }

    return .{
        .x = if (aspect_ratio > render_aspect) (width_f32 - w) / 2 else 0,
        .y = if (aspect_ratio > render_aspect) 0 else (height_f32 - h) / 2,
        .w = w,
        .h = h,
        .min_depth = 0,
        .max_depth = 1,
    };
}

// TODO: https://codeberg.org/ziglang/zig/issues/30048
pub const std_options: std.Options = .{
    .log_level = .err,
};

fn deinitC() callconv(.c) void {
    deinit();
}

fn initC(win: *c.SDL_Window, dev: *c.SDL_GPUDevice) callconv(.c) bool {
    init(win, dev) catch return false;
    return true;
}

fn renderC(time: f32) callconv(.c) bool {
    render(time) catch return false;
    return true;
}

// Export symbols if build configuration requires
comptime {
    if (@import("options").render_dynlib) {
        @export(&deinitC, .{ .name = "deinit" });
        @export(&initC, .{ .name = "init" });
        @export(&renderC, .{ .name = "render" });
    }
}
