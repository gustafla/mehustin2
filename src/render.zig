const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const c = @import("c");
const engine = @import("engine");
const timeline = engine.timeline;
const types = engine.types;
const BufferInfo = types.BufferInfo;
const TextureInfo = types.TextureInfo;
const TextureType = types.TextureType;
const TextureFormat = types.TextureFormat;
const VertexFormat = types.VertexFormat;
const schema = engine.schema;
const util = engine.util;
const sdlerr = engine.err.sdlerr;
const resource = engine.resource;
const options = @import("options");
const script = @import("script");
const config = script.config.render;

const builder = @import("render/builder.zig");
const shader = @import("render/shader.zig");
const time = @import("render/time.zig");

const log = std.log.scoped(.render);

// Generate helpers and metadata from script and config
const buffer_ids = @typeInfo(script.Buffer).@"enum".fields;
const texture_ids = @typeInfo(script.Texture).@"enum".fields;
const storage_buffer_ids = @typeInfo(script.StorageBuffer).@"enum".fields;
const SamplerEnum = builder.SamplerEnum(config);
const GraphicsPipelineKey = builder.GraphicsPipelineKey(config);
const ComputePipelineKey = builder.ComputePipelineKey(config);
const graphics_pipeline_set = builder.ComptimeSet(GraphicsPipelineKey);
const compute_pipeline_set = builder.ComptimeSet(ComputePipelineKey);
const usage_flags: builder.UsageFlags(config) = .init;

const max_attributes = blk: {
    const layout_decls = @typeInfo(script.layout).@"struct".decls;
    var max = 0;
    for (layout_decls) |decl| {
        const Layout = @field(script.layout, decl.name);
        const num_attributes = @typeInfo(Layout).@"struct".fields.len;
        if (num_attributes > max) max = num_attributes;
    }
    break :blk max;
};

var window: *c.SDL_Window = undefined;
var device: *c.SDL_GPUDevice = undefined;

var update_transfer_buffer: ?*c.SDL_GPUTransferBuffer = null;
var samplers: [config.samplers.len]?*c.SDL_GPUSampler = @splat(null);
var output_buffer: ?*c.SDL_GPUTexture = null;
var graphics_pipelines: [graphics_pipeline_set.keys.len]?*c.SDL_GPUGraphicsPipeline = @splat(null);
var compute_pipelines: [compute_pipeline_set.keys.len]?*c.SDL_GPUComputePipeline = @splat(null);
var color_targets: [config.color_targets.len]?*c.SDL_GPUTexture = @splat(null);
var depth_targets: [config.depth_targets.len]?*c.SDL_GPUTexture = @splat(null);

var textures: [texture_ids.len]?*c.SDL_GPUTexture = @splat(null);
var texture_infos: [texture_ids.len]TextureInfo = undefined;
var texture_sizes: [texture_ids.len]u32 = undefined;

var buffers: [buffer_ids.len]?*c.SDL_GPUBuffer = @splat(null);
var buffer_infos: [buffer_ids.len]BufferInfo = undefined;
var buffer_sizes: [buffer_ids.len]u32 = undefined;

var storage_buffers: [storage_buffer_ids.len]?*c.SDL_GPUBuffer = @splat(null);
var storage_buffer_sizes: [storage_buffer_ids.len]u32 = undefined;

fn resolveTextureFormat(format: TextureFormat) c.SDL_GPUTextureFormat {
    return switch (format) {
        .swapchain => c.SDL_GetGPUSwapchainTextureFormat(
            device,
            window,
        ),
        else => @intFromEnum(format),
    };
}

fn vertexFormatBase(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .int => |i| switch (i.bits) {
            8 => if (i.signedness == .signed) "byte" else "ubyte",
            16 => if (i.signedness == .signed) "short" else "ushort",
            32 => if (i.signedness == .signed) "int" else "uint",
            else => @compileError("Unsupported element type" ++ @typeName(T)),
        },
        .float => |f| switch (f.bits) {
            16 => "half",
            32 => "float",
            else => @compileError("Unsupported element type" ++ @typeName(T)),
        },
        else => unreachable,
    };
}

fn resolveVertexFormat(comptime T: type) c.SDL_GPUVertexElementFormat {
    const info = @typeInfo(T);

    const base, const len: ?comptime_int = comptime switch (info) {
        .int, .float => .{ vertexFormatBase(T), null },
        .array => |a| .{ vertexFormatBase(a.child), a.len },
        else => @compileError("Unsupported element type" ++ @typeName(T)),
    };

    const suffix = if (len) |l| std.fmt.comptimePrint("{}", .{l}) else "";
    return @intFromEnum(@field(VertexFormat, base ++ suffix));
}

pub fn deinit() void {
    if (update_transfer_buffer) |p| c.SDL_ReleaseGPUTransferBuffer(device, p);
    if (output_buffer) |p| c.SDL_ReleaseGPUTexture(device, p);
    for (depth_targets) |o| if (o) |p| c.SDL_ReleaseGPUTexture(device, p);
    for (color_targets) |o| if (o) |p| c.SDL_ReleaseGPUTexture(device, p);
    for (textures) |o| if (o) |p| c.SDL_ReleaseGPUTexture(device, p);
    for (samplers) |o| if (o) |p| c.SDL_ReleaseGPUSampler(device, p);
    for (buffers) |o| if (o) |p| c.SDL_ReleaseGPUBuffer(device, p);
    for (storage_buffers) |o| if (o) |p| c.SDL_ReleaseGPUBuffer(device, p);
    for (graphics_pipelines) |o| if (o) |p| c.SDL_ReleaseGPUGraphicsPipeline(device, p);
    for (compute_pipelines) |o| if (o) |p| c.SDL_ReleaseGPUComputePipeline(device, p);
}

fn initComputePipeline(
    io: Io,
    arena: Allocator,
    comptime key: ComputePipelineKey,
) !*c.SDL_GPUComputePipeline {
    log.debug("Initializing comp: {s}.{s}", .{ key.comp.file, key.comp.entrypoint });

    // Allocate SPIR-V file name
    const spirv_name = try shader.fileName(arena, "compute", key.comp);

    // Load SPIR-V binary
    const path = try resource.dataFilePath(arena, spirv_name);
    const data = try resource.loadFileZ(io, arena, path);

    var create_info = std.mem.zeroInit(c.SDL_GPUComputePipelineCreateInfo, key.comp_info);
    create_info.code_size = data.len;
    create_info.code = data.ptr;
    create_info.entrypoint = key.comp.entrypoint.ptr;
    create_info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    return try sdlerr(c.SDL_CreateGPUComputePipeline(device, &create_info));
}

fn initGraphicsPipeline(
    io: Io,
    arena: Allocator,
    comptime key: GraphicsPipelineKey,
) !*c.SDL_GPUGraphicsPipeline {
    const pipeline = key.pipeline;
    log.debug("Initializing vert: {s}.{s}, frag: {s}.{s}", .{
        pipeline.vert.file, pipeline.vert.entrypoint,
        pipeline.frag.file, pipeline.frag.entrypoint,
    });

    const vert = try shader.loadShader(io, arena, device, .vertex, pipeline.vert, key.vert_info);
    defer c.SDL_ReleaseGPUShader(device, vert);
    const frag = try shader.loadShader(io, arena, device, .fragment, pipeline.frag, key.frag_info);
    defer c.SDL_ReleaseGPUShader(device, frag);

    var color_target_descs: [GraphicsPipelineKey.max_color_targets]c.SDL_GPUColorTargetDescription = undefined;
    for (
        key.color_targets_buf[0..key.num_color_targets],
        color_target_descs[0..key.num_color_targets],
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

    var buffer_descs: [2]c.SDL_GPUVertexBufferDescription = undefined;
    var attribs: [max_attributes * 2]c.SDL_GPUVertexAttribute = undefined;
    var num_buffers: u32 = 0;
    var num_attribs: u32 = 0;

    inline for (.{
        .{ .layout = key.vertex_layout, .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX },
        .{ .layout = key.instance_layout, .input_rate = c.SDL_GPU_VERTEXINPUTRATE_INSTANCE },
    }) |buffer| {
        const Layout = buffer.layout orelse continue;
        if (@sizeOf(Layout) == 0) continue;

        buffer_descs[num_buffers] = .{
            .slot = num_buffers,
            .pitch = @sizeOf(Layout),
            .input_rate = buffer.input_rate,
            .instance_step_rate = 0,
        };

        var offset: u32 = 0;
        inline for (@typeInfo(Layout).@"struct".fields, Layout.locations) |field, location| {
            attribs[num_attribs] = .{
                .location = location,
                .buffer_slot = num_buffers,
                .format = resolveVertexFormat(field.type),
                .offset = offset,
            };
            offset += @sizeOf(field.type);
            num_attribs += 1;
        }

        num_buffers += 1;
    }

    return try sdlerr(c.SDL_CreateGPUGraphicsPipeline(device, &.{
        .vertex_shader = vert,
        .fragment_shader = frag,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &buffer_descs,
            .num_vertex_buffers = num_buffers,
            .vertex_attributes = &attribs,
            .num_vertex_attributes = num_attribs,
        },
        .primitive_type = @intFromEnum(pipeline.primitive_type),
        .rasterizer_state = pipeline.rasterizer_state.toSDL(),
        .multisample_state = .{
            .sample_count = @intFromEnum(key.sample_count),
            .enable_alpha_to_coverage = pipeline.enable_alpha_to_coverage,
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
            .color_target_descriptions = &color_target_descs,
            .depth_stencil_format = @intFromEnum(key.depth_target orelse
                TextureFormat.invalid),
            .has_depth_stencil_target = key.depth_target != null,
        },
        .props = 0,
    }));
}

fn initTextures(copy_pass: *c.SDL_GPUCopyPass) !u32 {
    // Initialize textures and transfer buffer
    var init_transfer_buffer_size: u32 = 0;
    var update_transfer_buffer_size: u32 = 0;

    inline for (
        texture_ids,
        usage_flags.textures,
        &textures,
        &texture_infos,
        &texture_sizes,
    ) |id, usage, *texture, *info, *size| {
        const texture_src = @field(script.texture, id.name);
        info.* = if (@hasDecl(texture_src, "info"))
            texture_src.info
        else
            try texture_src.create();
        size.* = c.SDL_CalculateGPUTextureFormatSize(
            @intFromEnum(info.format),
            info.width,
            info.height,
            info.depth,
        );

        // Guard against zero size
        if (size.* > 0) {
            log.debug("Initializing Texture {s} ({})", .{ id.name, id.value });

            texture.* =
                try sdlerr(c.SDL_CreateGPUTexture(device, &.{
                    .type = @intFromEnum(info.tex_type),
                    .format = @intFromEnum(info.format),
                    .usage = @bitCast(usage),
                    .width = info.width,
                    .height = info.height,
                    .layer_count_or_depth = info.depth,
                    .num_levels = info.mip_levels,
                    .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
                }));
        }

        if (@hasDecl(texture_src, "init")) {
            init_transfer_buffer_size += size.*;
        }

        if (@hasDecl(texture_src, "updateData")) {
            update_transfer_buffer_size += size.*;
        }
    }

    // Early return to avoid creating 0-sized transfer buffer
    if (init_transfer_buffer_size == 0) return update_transfer_buffer_size;

    const transfer_buffer = try sdlerr(c.SDL_CreateGPUTransferBuffer(device, &.{
        .size = init_transfer_buffer_size,
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
    }));
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    // Populate transfer buffer with data
    var tbp: [*]u8 = @ptrCast(try sdlerr(c.SDL_MapGPUTransferBuffer(
        device,
        transfer_buffer,
        false,
    )));
    inline for (texture_ids, texture_sizes) |id, size| {
        const texture_src = @field(script.texture, id.name);
        if (!@hasDecl(texture_src, "init")) continue;
        try texture_src.init(tbp[0..size]);
        tbp += size;
    }

    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    // Record transfer buffer uploads to textures
    var offset: u32 = 0;

    inline for (
        texture_ids,
        textures,
        texture_infos,
        texture_sizes,
    ) |id, texture, info, size| {
        if (!@hasDecl(@field(script.texture, id.name), "init")) continue;
        if (size > 0) {
            c.SDL_UploadToGPUTexture(
                copy_pass,
                &.{
                    .transfer_buffer = transfer_buffer,
                    .offset = offset,
                    .pixels_per_row = info.width,
                    .rows_per_layer = info.height,
                },
                &.{
                    .texture = texture,
                    .mip_level = 0,
                    .layer = 0,
                    .x = 0,
                    .y = 0,
                    .z = 0,
                    .w = info.width,
                    .h = info.height,
                    .d = info.depth,
                },
                false,
            );
        }
        offset += size;
    }

    return update_transfer_buffer_size;
}

fn initBuffers(copy_pass: *c.SDL_GPUCopyPass) !u32 {
    // Zero out infos in case init is not called but buffer is used
    @memset(&buffer_infos, .{ .num_elements = 0 });

    // Initialize buffers and transfer buffer
    var init_transfer_buffer_size: u32 = 0;
    var update_transfer_buffer_size: u32 = 0;

    inline for (
        buffer_ids,
        &buffers,
        &buffer_infos,
        &buffer_sizes,
    ) |id, *buffer, *info, *size| {
        const buffer_src = @field(script.buffer, id.name);
        const layout_size = @sizeOf(buffer_src.Layout);

        // Zero-size, no-create buffers may be used for instance counts
        if (layout_size == 0) {
            size.* = 0;
            continue;
        }

        const num_elements = if (@hasDecl(buffer_src, "data"))
            buffer_src.data.len
        else if (@hasDecl(buffer_src, "num_elements"))
            buffer_src.num_elements
        else
            try buffer_src.create();
        info.* = .{ .num_elements = num_elements };
        size.* = num_elements * layout_size;

        // Guard against zero elements returned
        if (size.* > 0) {
            log.debug("Initializing Buffer {s} ({}) with {s}", .{
                id.name, id.value, @typeName(buffer_src.Layout),
            });
            log.debug("    num_elements = {}, layout_size = {}, size = {}", .{
                num_elements, layout_size, size.*,
            });

            buffer.* = try sdlerr(c.SDL_CreateGPUBuffer(device, &.{
                .usage = if (@typeInfo(buffer_src.Layout) == .int)
                    c.SDL_GPU_BUFFERUSAGE_INDEX
                else
                    c.SDL_GPU_BUFFERUSAGE_VERTEX,
                .size = size.*,
            }));
        }

        if (@hasDecl(buffer_src, "data") or @hasDecl(buffer_src, "init")) {
            init_transfer_buffer_size += size.*;
        }

        if (@hasDecl(buffer_src, "updateData")) {
            update_transfer_buffer_size += size.*;
        }
    }

    // Early return to avoid creating 0-sized transfer buffer
    if (init_transfer_buffer_size == 0) return update_transfer_buffer_size;

    const transfer_buffer = try sdlerr(c.SDL_CreateGPUTransferBuffer(
        device,
        &.{
            .size = init_transfer_buffer_size,
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .props = 0,
        },
    ));
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    // Populate transfer buffer with data
    var tbp: [*]u8 = @ptrCast(try sdlerr(c.SDL_MapGPUTransferBuffer(
        device,
        transfer_buffer,
        false,
    )));

    inline for (buffer_ids, &buffer_infos, buffer_sizes) |id, *info, size| {
        const buffer_src = @field(script.buffer, id.name);
        if (@hasDecl(buffer_src, "data")) {
            const Child = @typeInfo(@TypeOf(buffer_src.data)).pointer.child;
            const dest: []Child = @ptrCast(@alignCast(tbp[0..size]));
            @memcpy(dest, buffer_src.data);
        } else if (@hasDecl(buffer_src, "init")) {
            try buffer_src.init(@ptrCast(@alignCast(tbp[0..size])), info);
        } else continue;
        tbp += size;
    }

    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    // Record transfer buffer uploads to buffers
    var offset: u32 = 0;

    inline for (buffer_ids, buffers, buffer_sizes) |id, buffer, size| {
        const buffer_src = @field(script.buffer, id.name);
        if (!@hasDecl(buffer_src, "data") and !@hasDecl(buffer_src, "init"))
            continue;
        if (size > 0) {
            c.SDL_UploadToGPUBuffer(
                copy_pass,
                &.{
                    .transfer_buffer = transfer_buffer,
                    .offset = offset,
                },
                &.{
                    .buffer = buffer,
                    .offset = 0,
                    .size = size,
                },
                false,
            );
        }
        offset += size;
    }

    return update_transfer_buffer_size;
}

fn initStorageBuffers(copy_pass: *c.SDL_GPUCopyPass) !u32 {
    // Initialize buffers and transfer buffer
    var init_transfer_buffer_size: u32 = 0;
    var update_transfer_buffer_size: u32 = 0;

    inline for (
        storage_buffer_ids,
        usage_flags.storage_buffers,
        &storage_buffers,
        &storage_buffer_sizes,
    ) |id, usage, *buffer, *size| {
        const storage_buffer_src = @field(script.storage_buffer, id.name);
        const num_elements =
            if (@hasDecl(storage_buffer_src, "header") and
            @hasDecl(storage_buffer_src, "data"))
                storage_buffer_src.data.len
            else if (@hasDecl(storage_buffer_src, "num_elements"))
                storage_buffer_src.num_elements
            else
                try storage_buffer_src.create();
        const header_size = @sizeOf(storage_buffer_src.Header);
        const layout_size = @sizeOf(storage_buffer_src.Element);
        size.* = header_size + (layout_size * num_elements);

        // Guard against zero size
        if (size.* > 0) {
            log.debug("Initializing Storage Buffer {s} ({})", .{
                id.name, id.value,
            });
            log.debug("    num_elements = {}, header_size = {}, layout_size = {}, size = {}", .{
                num_elements, header_size, layout_size, size.*,
            });

            buffer.* = try sdlerr(c.SDL_CreateGPUBuffer(device, &.{
                .usage = @bitCast(usage),
                .size = size.*,
            }));
        }

        if ((@hasDecl(storage_buffer_src, "header") and
            @hasDecl(storage_buffer_src, "data")) or
            @hasDecl(storage_buffer_src, "init"))
        {
            init_transfer_buffer_size += size.*;
        }

        if (@hasDecl(storage_buffer_src, "updateData")) {
            update_transfer_buffer_size += size.*;
        }
    }

    // Early return to avoid creating 0-sized transfer buffer
    if (init_transfer_buffer_size == 0) return update_transfer_buffer_size;

    const transfer_buffer = try sdlerr(c.SDL_CreateGPUTransferBuffer(
        device,
        &.{
            .size = init_transfer_buffer_size,
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .props = 0,
        },
    ));
    defer c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);

    // Populate transfer buffer with data
    var tbp: [*]u8 = @ptrCast(try sdlerr(c.SDL_MapGPUTransferBuffer(
        device,
        transfer_buffer,
        false,
    )));

    inline for (storage_buffer_ids, storage_buffer_sizes) |id, size| {
        const storage_buffer_src = @field(script.storage_buffer, id.name);
        if (@hasDecl(storage_buffer_src, "header") and
            @hasDecl(storage_buffer_src, "data"))
        {
            util.writeSSBO(
                storage_buffer_src.Header,
                storage_buffer_src.Element,
                tbp[0..size],
                storage_buffer_src.header,
                storage_buffer_src.data,
            );
        } else if (@hasDecl(storage_buffer_src, "init")) {
            try storage_buffer_src.init(tbp[0..size]);
        } else continue;
        tbp += size;
    }

    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    // Record transfer buffer uploads to buffers
    var offset: u32 = 0;

    inline for (
        storage_buffer_ids,
        storage_buffers,
        storage_buffer_sizes,
    ) |id, buffer, size| {
        const storage_buffer_src = @field(script.storage_buffer, id.name);
        if (!(@hasDecl(storage_buffer_src, "header") and
            @hasDecl(storage_buffer_src, "data")) and
            !@hasDecl(storage_buffer_src, "init")) continue;
        if (size > 0) {
            c.SDL_UploadToGPUBuffer(
                copy_pass,
                &.{
                    .transfer_buffer = transfer_buffer,
                    .offset = offset,
                },
                &.{
                    .buffer = buffer,
                    .offset = 0,
                    .size = size,
                },
                false,
            );
        }
        offset += size;
    }

    return update_transfer_buffer_size;
}

pub fn init(
    arena_ptr: *const Allocator,
    win: *c.SDL_Window,
    dev: *c.SDL_GPUDevice,
) !void {
    errdefer |e| {
        log.err("{s}", .{@errorName(e)});
        deinit();
    }

    window = win;
    device = dev;

    // Init io
    var threaded_io: Io.Threaded = .init_single_threaded;
    const io = threaded_io.io();

    // Pass arena to script
    const arena = arena_ptr.*;
    script.init(arena);

    // Initialize resources and update transfer buffer
    const update_transfer_buffer_size = blk: {
        var size: u32 = 0;

        // Start copy pass
        const cmdbuf = c.SDL_AcquireGPUCommandBuffer(device);
        errdefer _ = c.SDL_CancelGPUCommandBuffer(cmdbuf);
        const copy_pass = c.SDL_BeginGPUCopyPass(cmdbuf).?;

        size += try initTextures(copy_pass);
        size += try initBuffers(copy_pass);
        size += try initStorageBuffers(copy_pass);

        // Submit copy pass
        c.SDL_EndGPUCopyPass(copy_pass);
        try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));

        break :blk size;
    };

    if (update_transfer_buffer_size > 0) {
        update_transfer_buffer = try sdlerr(c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = update_transfer_buffer_size,
        }));
    } else {
        update_transfer_buffer = null;
    }

    for (config.samplers, &samplers) |smp, *sampler| {
        sampler.* = try sdlerr(c.SDL_CreateGPUSampler(device, &.{
            .min_filter = @intFromEnum(smp.min_filter),
            .mag_filter = @intFromEnum(smp.mag_filter),
            .mipmap_mode = @intFromEnum(smp.mipmap_mode),
            .address_mode_u = @intFromEnum(smp.address_mode_u),
            .address_mode_v = @intFromEnum(smp.address_mode_v),
            .address_mode_w = @intFromEnum(smp.address_mode_w),
            .mip_lod_bias = smp.mip_lod_bias,
            .max_anisotropy = smp.max_anisotropy,
            .compare_op = @intFromEnum(smp.compare_op),
            .min_lod = smp.min_lod,
            .max_lod = smp.max_lod,
            .enable_anisotropy = smp.enable_anisotropy,
            .enable_compare = smp.enable_compare,
        }));
    }

    output_buffer =
        try sdlerr(c.SDL_CreateGPUTexture(device, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = resolveTextureFormat(.swapchain),
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
            .width = script.config.main.width,
            .height = script.config.main.height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        }));

    for (
        config.color_targets,
        usage_flags.color_targets,
        &color_targets,
    ) |tex, usage, *texture| {
        texture.* =
            try sdlerr(c.SDL_CreateGPUTexture(device, &.{
                .type = c.SDL_GPU_TEXTURETYPE_2D,
                .format = resolveTextureFormat(tex.format),
                .usage = @bitCast(usage),
                .width = script.config.main.width * tex.p / tex.q,
                .height = script.config.main.height * tex.p / tex.q,
                .layer_count_or_depth = 1,
                .num_levels = 1,
                .sample_count = @intFromEnum(tex.sample_count),
            }));
    }

    for (
        config.depth_targets,
        usage_flags.depth_targets,
        &depth_targets,
    ) |tex, usage, *texture| {
        texture.* =
            try sdlerr(c.SDL_CreateGPUTexture(device, &.{
                .type = c.SDL_GPU_TEXTURETYPE_2D,
                .format = resolveTextureFormat(tex.format),
                .usage = @bitCast(usage),
                .width = script.config.main.width * tex.p / tex.q,
                .height = script.config.main.height * tex.p / tex.q,
                .layer_count_or_depth = 1,
                .num_levels = 1,
                .sample_count = @intFromEnum(tex.sample_count),
            }));
    }

    inline for (graphics_pipeline_set.keys, &graphics_pipelines) |key, *pipeline| {
        pipeline.* = try initGraphicsPipeline(io, arena, key);
    }

    inline for (compute_pipeline_set.keys, &compute_pipelines) |key, *pipeline| {
        pipeline.* = try initComputePipeline(io, arena, key);
    }
}

fn updateTextureData(tbp: [*]u8, base: u32) !u32 {
    // Populate transfer buffer with data
    var offset = base;

    inline for (
        texture_ids,
        texture_sizes,
    ) |id, size| {
        const texture_src = @field(script.texture, id.name);
        if (!@hasDecl(texture_src, "updateData")) continue;

        try texture_src.updateData(tbp[offset..][0..size]);
        offset += size;
    }

    return offset;
}

fn uploadTextures(copy_pass: *c.SDL_GPUCopyPass, base: u32) !u32 {
    // Record upload commands
    var offset = base;

    inline for (
        texture_ids,
        textures,
        texture_infos,
        texture_sizes,
    ) |id, texture, info, size| {
        const texture_src = @field(script.texture, id.name);
        if (!@hasDecl(texture_src, "updateData")) continue;

        if (size > 0) {
            c.SDL_UploadToGPUTexture(copy_pass, &.{
                .transfer_buffer = update_transfer_buffer,
                .offset = offset,
                .pixels_per_row = info.width,
                .rows_per_layer = info.height,
            }, &.{
                .texture = texture,
                .mip_level = 0,
                .layer = 0,
                .x = 0,
                .y = 0,
                .z = 0,
                .w = info.width,
                .h = info.height,
                .d = info.depth,
            }, true);
        }

        offset += size;
    }

    return offset;
}

fn updateBufferData(tbp: [*]u8, base: u32) !u32 {
    // Populate transfer buffer with data
    var offset = base;

    inline for (buffer_ids, buffer_sizes) |id, size| {
        const buffer_src = @field(script.buffer, id.name);
        if (!@hasDecl(buffer_src, "updateData")) continue;

        try buffer_src.updateData(@ptrCast(@alignCast(tbp[offset..][0..size])));

        offset += size;
    }

    // Update buffer infos
    inline for (buffer_ids, &buffer_infos) |id, *info| {
        const buffer_src = @field(script.buffer, id.name);
        if (!@hasDecl(buffer_src, "updateInfo")) continue;
        buffer_src.updateInfo(info);
    }

    return offset;
}

fn uploadBuffers(copy_pass: *c.SDL_GPUCopyPass, base: u32) !u32 {
    // Record upload commands
    var offset = base;

    inline for (buffer_ids, buffers, buffer_sizes) |id, buffer, size| {
        const buffer_src = @field(script.buffer, id.name);
        if (!@hasDecl(buffer_src, "updateData")) continue;

        if (size > 0) {
            c.SDL_UploadToGPUBuffer(copy_pass, &.{
                .transfer_buffer = update_transfer_buffer,
                .offset = offset,
            }, &.{
                .buffer = buffer,
                .offset = 0,
                .size = size,
            }, true);
        }

        offset += size;
    }

    return offset;
}

fn updateStorageBufferData(tbp: [*]u8, base: u32) !u32 {
    // Populate transfer buffer with data
    var offset = base;

    inline for (
        storage_buffer_ids,
        storage_buffer_sizes,
    ) |id, size| {
        const storage_buffer_src = @field(script.storage_buffer, id.name);
        if (!@hasDecl(storage_buffer_src, "updateData")) continue;

        try storage_buffer_src.updateData(tbp[offset..][0..size]);

        offset += size;
    }

    return offset;
}

fn uploadStorageBuffers(copy_pass: *c.SDL_GPUCopyPass, base: u32) !u32 {
    // Record upload commands
    var offset = base;

    inline for (
        storage_buffer_ids,
        storage_buffers,
        storage_buffer_sizes,
    ) |id, buffer, size| {
        const storage_buffer_src = @field(script.storage_buffer, id.name);
        if (!@hasDecl(storage_buffer_src, "updateData")) continue;

        if (size > 0) {
            c.SDL_UploadToGPUBuffer(copy_pass, &.{
                .transfer_buffer = update_transfer_buffer,
                .offset = offset,
            }, &.{
                .buffer = buffer,
                .offset = 0,
                .size = size,
            }, true);
        }

        offset += size;
    }

    return offset;
}

const RenderParameters = struct {
    cmdbuf: *c.SDL_GPUCommandBuffer,
    swapchain_texture: *c.SDL_GPUTexture,
    swapchain_viewport: *const c.SDL_GPUViewport,
    resolution_match: bool,
};

fn computePass(
    comptime clip: timeline.Clip,
    comptime pass: schema.Render.ComputePass,
    cmdbuf: *c.SDL_GPUCommandBuffer,
) !void {
    // Filter pass by clip id list
    comptime if (pass.condition) |clip_ids| {
        const idx = std.mem.findScalar(timeline.Clip, clip_ids, clip);
        if (idx == null) return;
    };

    var storage_texture_bindings: [pass.readwrite_storage_textures.len]c.SDL_GPUStorageTextureReadWriteBinding = undefined;
    for (pass.readwrite_storage_textures, &storage_texture_bindings) |name, *texture| {
        const reference = comptime builder.parseIndex(name) catch |e|
            @compileError(std.fmt.comptimePrint("{s}", .{@errorName(e)}));
        texture.* = .{
            .texture = if (reference) |result|
                @field(@This(), result.ref)[result.idx]
            else
                textures[@intFromEnum(@field(script.Texture, name))],
            .layer = 0, // TODO: allow configuration
            .mip_level = 0, // TODO: allow configuration
            .cycle = true,
        };
    }

    var storage_buffer_bindings: [pass.readwrite_storage_buffers.len]c.SDL_GPUStorageBufferReadWriteBinding = undefined;
    for (pass.readwrite_storage_buffers, &storage_buffer_bindings) |name, *buffer| {
        const idx = @intFromEnum(@field(script.StorageBuffer, name));
        buffer.* = .{
            .buffer = storage_buffers[idx],
            .cycle = true,
        };
    }

    const compute_pass = c.SDL_BeginGPUComputePass(
        cmdbuf,
        &storage_texture_bindings,
        storage_texture_bindings.len,
        &storage_buffer_bindings,
        storage_buffer_bindings.len,
    );

    inline for (pass.dispatches) |dispatch| {
        // Filter dispatch by clip id list
        comptime if (dispatch.condition) |clip_ids| {
            const idx = std.mem.findScalar(timeline.Clip, clip_ids, clip);
            if (idx == null) continue;
        };

        for (dispatch.samplers, 0..) |tex, slot| {
            const reference = comptime builder.parseIndex(tex.texture) catch |e|
                @compileError(std.fmt.comptimePrint("{s}", .{@errorName(e)}));
            c.SDL_BindGPUComputeSamplers(compute_pass, @intCast(slot), &.{
                .texture = if (reference) |result|
                    @field(@This(), result.ref)[result.idx]
                else
                    textures[@intFromEnum(@field(script.Texture, tex.texture))],
                .sampler = samplers[@intFromEnum(@field(SamplerEnum, tex.sampler))],
            }, 1);
        }

        for (dispatch.readonly_storage_textures, 0..) |name, slot| {
            const reference = comptime builder.parseIndex(name) catch |e|
                @compileError(std.fmt.comptimePrint("{s}", .{@errorName(e)}));
            c.SDL_BindGPUComputeStorageTextures(
                compute_pass,
                @intCast(slot),
                if (reference) |result|
                    &@field(@This(), result.ref)[result.idx]
                else
                    &textures[@intFromEnum(@field(script.Texture, name))],
                1,
            );
        }

        for (dispatch.readonly_storage_buffers, 0..) |name, slot| {
            const idx = @intFromEnum(@field(script.StorageBuffer, name));
            c.SDL_BindGPUComputeStorageBuffers(
                compute_pass,
                @intCast(slot),
                &storage_buffers[idx],
                1,
            );
        }

        const pipeline_key = comptime ComputePipelineKey.init(pass, dispatch);
        const pipeline_index = comptime compute_pipeline_set.getIndex(pipeline_key);
        c.SDL_BindGPUComputePipeline(compute_pass, compute_pipelines[pipeline_index]);

        c.SDL_DispatchGPUCompute(
            compute_pass,
            dispatch.groupcount.x,
            dispatch.groupcount.y,
            dispatch.groupcount.z,
        );
    }

    c.SDL_EndGPUComputePass(compute_pass);
}

fn renderPass(
    comptime clip: timeline.Clip,
    comptime pass: schema.Render.RenderPass,
    parm: RenderParameters,
) !void {
    // Filter pass by clip id list
    comptime if (pass.condition) |clip_ids| {
        const idx = std.mem.findScalar(timeline.Clip, clip_ids, clip);
        if (idx == null) return;
    };

    // Initialize color target infos
    const color_target_infos = blk: {
        var infos: [pass.color_targets.len]c.SDL_GPUColorTargetInfo = undefined;
        for (pass.color_targets, &infos) |target, *info| {
            info.* = .{
                .texture = switch (target.target) {
                    .index => |index| color_targets[index],
                    .swapchain => if (parm.resolution_match)
                        parm.swapchain_texture
                    else
                        output_buffer,
                },
                .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                .load_op = @intFromEnum(target.load_op),
                .store_op = @intFromEnum(target.store_op),
                .resolve_texture = if (target.resolve_target) |resolve|
                    switch (resolve) {
                        .index => |index| color_targets[index],
                        .swapchain => if (parm.resolution_match)
                            parm.swapchain_texture
                        else
                            output_buffer,
                    }
                else
                    null,
                .cycle = target.load_op != .load,
                .cycle_resolve_texture = target.load_op != .load, // TODO: ?
            };
        }
        break :blk infos;
    };

    // Push pass uniforms
    const p: f32, const q: f32 = switch (pass.color_targets[0].target) {
        .index => |index| .{
            @floatFromInt(config.color_targets[index].p),
            @floatFromInt(config.color_targets[index].q),
        },
        .swapchain => .{ 1, 1 },
    };
    const fragment_pass_uniforms: extern struct {
        target_scale: f32,
    } = .{
        .target_scale = p / q,
    };
    c.SDL_PushGPUFragmentUniformData(
        parm.cmdbuf,
        1,
        @ptrCast(&fragment_pass_uniforms),
        @sizeOf(@TypeOf(fragment_pass_uniforms)),
    );

    // Begin render pass
    const render_pass = c.SDL_BeginGPURenderPass(
        parm.cmdbuf,
        &color_target_infos,
        @intCast(pass.color_targets.len),
        if (pass.depth_target) |target| &.{
            .texture = depth_targets[target.target],
            .clear_depth = 1,
            .load_op = @intFromEnum(target.load_op),
            .store_op = @intFromEnum(target.store_op),
            .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE,
            .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE,
            .cycle = true,
        } else null,
    );

    // Set viewport if necessary
    const target_swapchain = comptime for (pass.color_targets) |target| {
        if (target.target == .swapchain) break true;
    } else false;
    if (target_swapchain and parm.resolution_match) {
        c.SDL_SetGPUViewport(render_pass, parm.swapchain_viewport);
    }

    // Record drawcalls
    inline for (pass.drawcalls) |drawcall| {
        // Filter drawcall by clip id list
        comptime if (drawcall.condition) |clip_ids| {
            const idx = std.mem.findScalar(timeline.Clip, clip_ids, clip);
            if (idx == null) continue;
        };

        // Bind vertex buffer, storing number of instances to draw
        var num_buffers: u32 = 0;
        var num_vertices: u32 = drawcall.num_vertices orelse 3;
        var first_vertex: u32 = 0;
        if (drawcall.vertex_buffer) |name| {
            const idx = @intFromEnum(@field(script.Buffer, name));
            if (buffer_sizes[idx] > 0) {
                c.SDL_BindGPUVertexBuffers(
                    render_pass,
                    num_buffers,
                    &.{ .buffer = buffers[idx], .offset = 0 },
                    1,
                );
                num_buffers += 1;
            }
            if (drawcall.num_vertices == null) {
                num_vertices = buffer_infos[idx].num_elements;
            }
            first_vertex = buffer_infos[idx].first_element;
        }

        // Bind instance buffer, storing number of instances to draw
        var num_instances: u32 = drawcall.num_instances orelse 1;
        var first_instance: u32 = 0;
        if (drawcall.instance_buffer) |name| {
            const idx = @intFromEnum(@field(script.Buffer, name));
            if (buffer_sizes[idx] > 0) {
                c.SDL_BindGPUVertexBuffers(
                    render_pass,
                    num_buffers,
                    &.{ .buffer = buffers[idx], .offset = 0 },
                    1,
                );
                num_buffers += 1;
            }
            if (drawcall.num_instances == null) {
                num_instances = buffer_infos[idx].num_elements;
            }
            first_instance = buffer_infos[idx].first_element;
        }

        // Bind index buffer, overriding num_vertices
        if (drawcall.index_buffer) |name| {
            const idx = @intFromEnum(@field(script.Buffer, name));
            const info = @typeInfo(@field(script.buffer, name).Layout);
            std.debug.assert(info.int.signedness == .unsigned);
            const element_size = switch (info.int.bits) {
                16 => c.SDL_GPU_INDEXELEMENTSIZE_16BIT,
                32 => c.SDL_GPU_INDEXELEMENTSIZE_32BIT,
                else => unreachable,
            };
            c.SDL_BindGPUIndexBuffer(
                render_pass,
                &.{ .buffer = buffers[idx], .offset = 0 },
                element_size,
            );
            if (drawcall.num_vertices == null) {
                num_vertices = buffer_infos[idx].num_elements;
            }
            first_vertex = buffer_infos[idx].first_element;
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
                const reference = comptime builder.parseIndex(tex.texture) catch |e|
                    @compileError(std.fmt.comptimePrint("{s}", .{@errorName(e)}));
                stage.bind(render_pass, @intCast(slot), &.{
                    .texture = if (reference) |result|
                        @field(@This(), result.ref)[result.idx]
                    else
                        textures[@intFromEnum(@field(script.Texture, tex.texture))],
                    .sampler = samplers[@intFromEnum(@field(SamplerEnum, tex.sampler))],
                }, 1);
            }
        }

        // Bind storage buffers
        inline for (.{
            .{
                .bind = c.SDL_BindGPUVertexStorageBuffers,
                .storage_buffers = drawcall.vertex_storage_buffers,
            },
            .{
                .bind = c.SDL_BindGPUFragmentStorageBuffers,
                .storage_buffers = drawcall.fragment_storage_buffers,
            },
        }) |stage| {
            inline for (stage.storage_buffers, 0..) |name, slot| {
                const idx = @intFromEnum(@field(script.StorageBuffer, name));
                stage.bind(render_pass, @intCast(slot), &storage_buffers[idx], 1);
            }
        }

        inline for (drawcall.pipelines) |pipeline| {
            // Find matching pipeline index from pipeline_keys at compile time
            const pipeline_key = comptime GraphicsPipelineKey.init(pass, drawcall, pipeline);
            const pipeline_index = comptime graphics_pipeline_set.getIndex(pipeline_key);
            c.SDL_BindGPUGraphicsPipeline(render_pass, graphics_pipelines[pipeline_index]);
            if (drawcall.index_buffer == null) {
                c.SDL_DrawGPUPrimitives(
                    render_pass,
                    num_vertices,
                    num_instances,
                    first_vertex,
                    first_instance,
                );
            } else {
                c.SDL_DrawGPUIndexedPrimitives(
                    render_pass,
                    num_vertices,
                    num_instances,
                    first_vertex,
                    0,
                    first_instance,
                );
            }
        }
    }

    c.SDL_EndGPURenderPass(render_pass);
}

fn recordPasses(
    comptime clip: timeline.Clip,
    parm: RenderParameters,
) !void {
    inline for (config.passes) |pass| {
        switch (pass) {
            .render => |rpass| try renderPass(clip, rpass, parm),
            .compute => |cpass| try computePass(clip, cpass, parm.cmdbuf),
        }
    }
}

pub fn render() !void {
    errdefer |e| log.err("{s}", .{@errorName(e)});

    // Acquire command buffer
    const cmdbuf = try sdlerr(c.SDL_AcquireGPUCommandBuffer(device));

    {
        errdefer _ = c.SDL_CancelGPUCommandBuffer(cmdbuf);

        // Acquire swapchain texture
        var swapchain_width: u32 = 0;
        var swapchain_height: u32 = 0;
        var swapchain_texture_opt: ?*c.SDL_GPUTexture = null;

        try sdlerr(c.SDL_WaitAndAcquireGPUSwapchainTexture(
            cmdbuf,
            window,
            &swapchain_texture_opt,
            &swapchain_width,
            &swapchain_height,
        ));

        const swapchain_texture = swapchain_texture_opt orelse {
            _ = c.SDL_CancelGPUCommandBuffer(cmdbuf);
            return;
        };

        const resolution_match =
            (swapchain_width == script.config.main.width and swapchain_height >= script.config.main.height) or
            (swapchain_height == script.config.main.height and swapchain_width >= script.config.main.width);

        // Compute viewport preserving aspect ratio rendering to swapchain
        const swapchain_viewport = viewport(swapchain_width, swapchain_height);

        // Measure this frame's timestamp after the swapchain acquisition blocked
        const timestamp = time.getTime() * timeline.bps;

        // Update script frame
        const frame_state = script.frame.update(timestamp);

        // Update dynamic buffers
        if (update_transfer_buffer) |transfer_buffer| {
            {
                const tbp: [*]u8 = @ptrCast(try sdlerr(c.SDL_MapGPUTransferBuffer(
                    device,
                    transfer_buffer,
                    true,
                )));
                defer c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

                var offset: u32 = 0;
                offset = try updateTextureData(tbp, offset);
                offset = try updateBufferData(tbp, offset);
                offset = try updateStorageBufferData(tbp, offset);
            }

            {
                const copy_pass = c.SDL_BeginGPUCopyPass(cmdbuf).?;
                defer c.SDL_EndGPUCopyPass(copy_pass);

                var offset: u32 = 0;
                offset = try uploadTextures(copy_pass, offset);
                offset = try uploadBuffers(copy_pass, offset);
                offset = try uploadStorageBuffers(copy_pass, offset);
            }
        }

        // Update frame uniforms
        const frame_uniforms = frame_state.uniforms();
        c.SDL_PushGPUVertexUniformData(
            cmdbuf,
            0,
            @ptrCast(&frame_uniforms.vertex),
            @sizeOf(@TypeOf(frame_uniforms.vertex)),
        );
        c.SDL_PushGPUFragmentUniformData(
            cmdbuf,
            0,
            @ptrCast(&frame_uniforms.fragment),
            @sizeOf(@TypeOf(frame_uniforms.fragment)),
        );
        // Reminder, per shader uniform counts are hardcoded at shader creation:
        comptime std.debug.assert(builder.num_fragment_uniform_buffers == 2);

        // Record passes (specializes the renderer for each clip configuration)
        switch (frame_state.clip) {
            .end => {},
            inline else => |clip| try recordPasses(clip, .{
                .cmdbuf = cmdbuf,
                .swapchain_texture = swapchain_texture,
                .swapchain_viewport = &swapchain_viewport,
                .resolution_match = resolution_match,
            }),
        }

        // Blit output_buffer to swapchain when necessary
        if (!resolution_match) {
            c.SDL_BlitGPUTexture(cmdbuf, &.{
                .source = .{
                    .texture = output_buffer,
                    .w = script.config.main.width,
                    .h = script.config.main.height,
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
    }

    try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));
}

fn viewport(target_width: u32, target_height: u32) c.SDL_GPUViewport {
    if (target_width == 0 or target_height == 0) {
        return std.mem.zeroes(c.SDL_GPUViewport);
    }

    const width_f32: f32 = @floatFromInt(target_width);
    const height_f32: f32 = @floatFromInt(target_height);
    const aspect_ratio = width_f32 / height_f32;
    const aspect = engine.util.aspectRatio(script.config.main);

    var w = width_f32;
    var h = height_f32;
    if (aspect_ratio > aspect) {
        w = height_f32 * aspect;
    } else {
        h = width_f32 / aspect;
    }

    return .{
        .x = if (aspect_ratio > aspect) (width_f32 - w) / 2 else 0,
        .y = if (aspect_ratio > aspect) 0 else (height_f32 - h) / 2,
        .w = w,
        .h = h,
        .min_depth = 0,
        .max_depth = 1,
    };
}

fn deinitC() callconv(.c) void {
    deinit();
}

fn initC(
    arena: *const Allocator,
    win: *c.SDL_Window,
    dev: *c.SDL_GPUDevice,
) callconv(.c) bool {
    init(arena, win, dev) catch return false;
    return true;
}

fn renderC() callconv(.c) bool {
    render() catch return false;
    return true;
}

pub fn pause(state: bool) callconv(.c) void {
    time.pause(state);
}

pub fn isPaused() callconv(.c) bool {
    return time.paused;
}

pub fn seek(to_sec: f32) callconv(.c) void {
    time.seek(to_sec);
}

pub fn getTime() callconv(.c) f32 {
    return time.getTime();
}

// Export symbols if build configuration requires
comptime {
    if (options.render_dynlib) {
        @export(&deinitC, .{ .name = "deinit" });
        @export(&initC, .{ .name = "init" });
        @export(&renderC, .{ .name = "render" });
        @export(&pause, .{ .name = "pause" });
        @export(&isPaused, .{ .name = "isPaused" });
        @export(&seek, .{ .name = "seek" });
        @export(&getTime, .{ .name = "getTime" });
    }
}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .err,
};
