const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const config: Config = @import("render.zon");
const main_config = @import("config.zon");
const options = @import("options");

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

fn enumFieldNameFromC(
    comptime name: []const u8,
) [:0]u8 {
    // Convert to lowercase
    var buf: [name.len + 1]u8 = undefined;
    for (name, 0..) |chr, i| {
        buf[i] = std.ascii.toLower(chr);
    }

    buf[name.len] = 0;
    return buf[0..name.len :0];
}

fn EnumFromC(
    comptime type_name: []const u8,
    comptime opt: struct {
        prefix: []const u8 = "SDL_GPU",
        extra_fields: []const @Type(.enum_literal) = &.{},
    },
) type {
    @setEvalBranchQuota(100000);
    const Tag = @field(c, opt.prefix ++ type_name);
    const c_decls = @typeInfo(c).@"struct".decls;

    // Type name: "VertexElementFormat"
    // Variant: "VERTEXELEMENTFORMAT"
    var variant: [type_name.len]u8 = undefined;
    for (type_name, 0..) |chr, i| {
        variant[i] = std.ascii.toUpper(chr);
    }

    var fields: [c_decls.len]std.builtin.Type.EnumField = undefined;
    var index: usize = 0;
    var max_val: Tag = 0;

    // Search prefix: "SDL_GPU_VERTEXELEMENTFORMAT"
    const search_prefix = opt.prefix ++ "_" ++ variant;
    for (c_decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, search_prefix)) {
            const val = @field(c, decl.name);
            if (max_val < val) {
                max_val = val;
            }
            const raw_name = decl.name[search_prefix.len + 1 ..];
            fields[index] = .{
                .name = enumFieldNameFromC(raw_name),
                .value = val,
            };
            index += 1;
        }
    }

    for (opt.extra_fields) |extra| {
        max_val += 1;
        fields[index] = .{
            .name = @tagName(extra),
            .value = max_val,
        };
        index += 1;
    }

    // TODO: Change this to @Enum in 0.16
    return @Type(.{ .@"enum" = .{
        .decls = &.{},
        .tag_type = Tag,
        .fields = fields[0..index],
        .is_exhaustive = true,
    } });
}

const VertexFormat = EnumFromC("VertexElementFormat", .{});

fn vertexFormatLen(format: VertexFormat) u32 {
    return switch (format) {
        .invalid => unreachable,
        inline else => |tag| comptime blk: {
            @setEvalBranchQuota(10000);
            const name = @tagName(tag);

            var index: usize = 0;
            while (index < name.len and std.ascii.isAlphabetic(name[index])) {
                index += 1;
            }

            const scalar_str = name[0..index];
            const Scalar = enum { byte, ubyte, short, ushort, half, int, uint, float };
            const scalar_tag = std.meta.stringToEnum(Scalar, scalar_str) orelse unreachable;

            const scalar_len = switch (scalar_tag) {
                .byte, .ubyte => 1,
                .short, .ushort, .half => 2,
                .int, .uint, .float => 4,
            };

            const count: u32 = if (index < name.len and std.ascii.isDigit(name[index]))
                name[index] - '0'
            else
                1;

            break :blk scalar_len * count;
        },
    };
}

const VertexAttributes = packed struct {
    coords: bool = false,
    normals: bool = false,
    colors: bool = false,
    uvs: bool = false,
};

fn attribFormat(comptime attrib_name: []const u8) VertexFormat {
    const field = std.meta.stringToEnum(
        std.meta.FieldEnum(VertexAttributes),
        attrib_name,
    ) orelse unreachable;
    return switch (field) {
        .coords => .float3,
        .normals => .float3,
        .colors => .float3,
        .uvs => .float2,
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

// Assert that structs above have matching fields
comptime {
    const attributes_fields = @typeInfo(VertexAttributes).@"struct".fields;
    const data_fields = @typeInfo(VertexData).@"struct".fields;
    const buffers_fields = @typeInfo(VertexBuffers).@"struct".fields;
    for (attributes_fields, data_fields, buffers_fields) |a, d, b| {
        std.debug.assert(std.mem.eql(u8, a.name, d.name));
        std.debug.assert(std.mem.eql(u8, a.name, b.name));
    }
}

const TextureFormat = EnumFromC(
    "TextureFormat",
    .{ .extra_fields = &.{.swapchain} },
);

fn resolveTextureFormat(format: TextureFormat) c.SDL_GPUTextureFormat {
    return switch (format) {
        .swapchain => c.SDL_GetGPUSwapchainTextureFormat(
            device,
            window,
        ),
        else => @intFromEnum(format),
    };
}

const PrimitiveType = EnumFromC("PrimitiveType", .{});
const CompareOp = EnumFromC("CompareOp", .{});
const BlendFactor = EnumFromC("BlendFactor", .{});
const BlendOp = EnumFromC("BlendOp", .{});

const UniformData = enum {
    matrices,
    shadertoy,
};

const ColorTarget = union(enum) {
    index: usize,
    swapchain,
};

const BlendState = struct {
    src_color: BlendFactor = .src_alpha,
    dst_color: BlendFactor = .one_minus_src_alpha,
    color_op: BlendOp = .add,
    src_alpha: BlendFactor = .one,
    dst_alpha: BlendFactor = .one_minus_src_alpha,
    alpha_op: BlendOp = .add,
    enable: bool = false,

    pub fn toSDL(self: @This()) c.SDL_GPUColorTargetBlendState {
        return .{
            .src_color_blendfactor = @intFromEnum(self.src_color),
            .dst_color_blendfactor = @intFromEnum(self.dst_color),
            .color_blend_op = @intFromEnum(self.color_op),
            .src_alpha_blendfactor = @intFromEnum(self.src_alpha),
            .dst_alpha_blendfactor = @intFromEnum(self.dst_alpha),
            .alpha_blend_op = @intFromEnum(self.alpha_op),
            .enable_blend = self.enable,
            .enable_color_write_mask = false,
        };
    }
};

const Pipeline = struct {
    vert: []const u8 = "tri.vert",
    frag: []const u8,
    vertex_attributes: VertexAttributes = .{},
    instance_attributes: []const VertexFormat = &.{},
    primitive_type: PrimitiveType = .trianglestrip,
    depth_test: ?struct {
        compare_op: CompareOp = .less_or_equal,
        enable: bool = true,
        write: bool = true,
    } = null,
    blend_states: []const BlendState = &.{},
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
    color_textures: []const TextureFormat = &.{},
    depth_textures: []const TextureFormat = &.{},
    vertices: []const VertexSource,
    instances: []const InstanceSource,
    fonts: []const Font,
    passes: []const Pass,
    noise_size: u32 = 256,
    noise_scale: f32 = 0.5,
};

// Compute upper bounds from config
fn foldConfig(
    parent: anytype,
    comptime fields: []const []const u8,
    fold: anytype,
) @TypeOf(fold.init) {
    const Parent = @TypeOf(parent);
    const info = @typeInfo(Parent);
    const is_slice = info == .pointer and info.pointer.size == .slice;
    const is_string = is_slice and info.pointer.child == u8;
    const is_iterable = (is_slice or info == .array) and !is_string;

    // Base case, at leaf, yield it's value, optionally transformed via `map`.
    if (fields.len == 0 and !is_iterable) {
        if (@hasDecl(fold, "map")) {
            return fold.map(parent);
        }
        return parent;
    }

    // Then, if current field access works, always descent (e.g. `[]T.len`)
    if (fields.len > 0 and @hasField(Parent, fields[0])) {
        const child = @field(parent, fields[0]);
        return foldConfig(child, fields[1..], fold);
    }

    // Finally, try iterating current parent
    var acc = fold.init;
    for (parent) |elem| {
        const val = foldConfig(elem, fields, fold);
        acc = fold.op(acc, val);
    }

    return acc;
}

const MaxField = struct {
    const init = 0;
    const T = @TypeOf(@This().init);
    fn op(acc: T, val: T) T {
        return @max(acc, val);
    }
};

const SumField = struct {
    const init = 0;
    const T = @TypeOf(@This().init);
    fn op(acc: T, val: T) T {
        return acc + val;
    }
};

const max_color_targets = foldConfig(config.passes, &.{
    "color_targets",
    "len",
}, MaxField);
const max_instance_attributes = foldConfig(config.passes, &.{
    "drawcalls",
    "pipeline",
    "instance_attributes",
    "len",
}, MaxField);

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
    color_targets_buf: [max_color_targets]TextureFormat,
    num_color_targets: u32,
    depth_target: ?TextureFormat,
};

// Generate a comptime array of all unique pipeline keys from config
const pipeline_keys = init: {
    // Find upper bound for pipelines defined in render config
    const n = foldConfig(config.passes, &.{ "drawcalls", "len" }, SumField);

    // Initialize unique map keys with O(n^2) filtering
    var keys: [n]PipelineKey = undefined;
    var num_keys = 0;
    for (config.passes) |pass| {
        var color_targets = std.mem.zeroes([max_color_targets]TextureFormat);
        for (pass.color_targets, 0..) |format, i| {
            color_targets[i] = switch (format) {
                .index => |idx| config.color_textures[idx],
                .swapchain => .swapchain,
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
    const CountImages = struct {
        const init: usize = 0;
        const op = SumField.op;
        fn map(texture: Texture) usize {
            return @intFromBool(texture == .image);
        }
    };
    const n = foldConfig(config.passes, &.{ "drawcalls", "vertex_samplers" }, CountImages) +
        foldConfig(config.passes, &.{ "drawcalls", "fragment_samplers" }, CountImages);

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
    format: TextureFormat,
    wh: struct { width: u32 = render_width, height: u32 = render_height },
) !*c.SDL_GPUTexture {
    return try sdlerr(c.SDL_CreateGPUTexture(device, &.{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = resolveTextureFormat(format),
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
    format: TextureFormat,
    wh: struct { width: u32 = render_width, height: u32 = render_height },
) !*c.SDL_GPUTexture {
    return try sdlerr(c.SDL_CreateGPUTexture(device, &.{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = resolveTextureFormat(format),
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

    var color_targets: [max_color_targets]c.SDL_GPUColorTargetDescription = undefined;
    for (
        key.color_targets_buf[0..key.num_color_targets],
        color_targets[0..key.num_color_targets],
        0..,
    ) |target_def, *target, blend_idx| {
        target.* = .{
            .format = resolveTextureFormat(target_def),
            .blend_state = if (blend_idx < pipeline.blend_states.len)
                pipeline.blend_states[blend_idx].toSDL()
            else
                std.mem.zeroes(c.SDL_GPUColorTargetBlendState),
        };
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
        const vertex_format = attribFormat(field.name);
        const enabled = @field(pipeline.vertex_attributes, field.name);
        if (enabled) {
            buffers[num_buffers] = .{
                .slot = num_buffers,
                .pitch = vertexFormatLen(vertex_format),
                .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                .instance_step_rate = 0,
            };
            attribs[num_attribs] = .{
                .location = @intCast(location),
                .buffer_slot = num_buffers,
                .format = @intFromEnum(vertex_format),
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
                .format = @intFromEnum(attrib),
                .offset = instance_attrib_offset,
            };
            instance_attrib_offset += vertexFormatLen(attrib);
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

fn initBuffer(
    T: type,
    data: []const T,
    usage: c.SDL_GPUBufferUsageFlags,
) !*c.SDL_GPUBuffer {
    const size: u32 = @intCast(data.len * @sizeOf(T));

    const buffer = try sdlerr(c.SDL_CreateGPUBuffer(
        device,
        &.{
            .size = size,
            .usage = usage,
            .props = 0,
        },
    ));
    errdefer c.SDL_ReleaseGPUBuffer(device, buffer);

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

    output_buffer = try initColorTexture(.swapchain, .{});
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
    errdefer c.SDL_ReleaseGPUTransferBuffer(device, noise_transfer);
    noise_texture = try initColorTexture(
        .r8_unorm,
        .{ .width = config.noise_size, .height = config.noise_size },
    );
    errdefer c.SDL_ReleaseGPUTexture(device, noise_texture);

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
        errdefer c.SDL_ReleaseGPUTexture(device, texture.*);
    }

    for (config.instances, &instance_buffers, &instance_counts) |def, *buffer, *count| {
        const text = def.text;
        const size = config.fonts[text.font].size;
        const glyphs = &font_glyph_data[text.font];
        count.* = try initText(text.str, size, buffer, glyphs);
        errdefer c.SDL_ReleaseGPUBuffer(device, buffer.*);
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
            var targets = std.mem.zeroes([max_color_targets]TextureFormat);
            for (pass.color_targets, targets[0..pass.color_targets.len]) |format, *target| {
                target.* = switch (format) {
                    .index => |i| config.color_textures[i],
                    .swapchain => .swapchain,
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
                        .matrices => .{
                            @ptrCast(&matrices),
                            @sizeOf(@TypeOf(matrices)),
                        },
                        .shadertoy => .{
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

var host_print: ?*const fn ([*]const u8, usize) callconv(.c) void = null;

// Export symbols if build configuration requires
comptime {
    if (options.render_dynlib) {
        @export(&deinitC, .{ .name = "deinit" });
        @export(&initC, .{ .name = "init" });
        @export(&renderC, .{ .name = "render" });
        @export(&host_print, .{ .name = "host_print" });
    }
}

fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const print = host_print orelse return;

    var buf: [1024]u8 = undefined;

    const prefix = @tagName(level) ++
        if (scope == std.log.default_log_scope)
            ""
        else
            ("(" ++ @tagName(scope) ++ ")") ++
                ": ";

    const full_fmt = prefix ++ format ++ " (in dynlib)";
    const msg = std.fmt.bufPrint(&buf, full_fmt, args) catch blk: {
        break :blk "Log message too long";
    };

    print(msg.ptr, msg.len);
}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .err,
    .logFn = if (options.render_dynlib) myLogFn else std.log.defaultLog,
};
