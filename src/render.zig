const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const config: Config = @import("render.zon");
const main_config = @import("config.zon");
const options = @import("options");

const c = @import("render/c.zig").c;
const schema = @import("render/schema.zig");
const Config = schema.Config;
const shader = @import("render/shader.zig");
const types = @import("render/types.zig");
const TextureType = types.TextureType;
const TextureFormat = types.TextureFormat;
const script = @import("script.zig");
const sdlerr = @import("err.zig").sdlerr;

const log = std.log.scoped(.render);

// Generate helpers and metadata from config
const layout_pitch = schema.bufferLayoutPitch(config)[0..].*;
pub const BufferLayoutEnum = schema.BufferLayoutEnum(config);
const BufferEnum = schema.BufferEnum(config);
const TextureEnum = schema.TextureEnum(config);
const SamplerEnum = schema.SamplerEnum(config);
const PipelineKey = schema.PipelineKey(config);
const pipeline_set = schema.ComptimeSet(PipelineKey);

pub const width: f32 = @floatFromInt(main_config.width);
pub const height: f32 = @floatFromInt(main_config.height);
pub const aspect = width / height;
const max_attributes = schema.fold(config, &.{
    "layouts",
    "format",
    "len",
}, schema.max_field);

// TODO: https://github.com/ziglang/zig/issues/25026
// var debug_allocator: std.heap.DebugAllocator(.{}) = undefined;
var gpa: Allocator = undefined;
var window: *c.SDL_Window = undefined;
var device: *c.SDL_GPUDevice = undefined;

var samplers: [config.samplers.len]*c.SDL_GPUSampler = undefined;
var output_buffer: *c.SDL_GPUTexture = undefined;
var pipelines: [pipeline_set.keys.len]*c.SDL_GPUGraphicsPipeline = undefined;
var color_targets: [config.color_targets.len]*c.SDL_GPUTexture = undefined;
var depth_targets: [config.depth_targets.len]*c.SDL_GPUTexture = undefined;

var textures: [config.textures.len]*c.SDL_GPUTexture = undefined;
var texture_infos: [config.textures.len]script.TextureInit = undefined;
var texture_sizes: [config.textures.len]u32 = undefined;
var texture_transfer: ?*c.SDL_GPUTransferBuffer = undefined;

var buffers: [config.buffers.len]*c.SDL_GPUBuffer = undefined;
var buffer_infos: [config.buffers.len]script.BufferInit = undefined;
var buffer_sizes: [config.buffers.len]u32 = undefined;
var buffer_transfer: ?*c.SDL_GPUTransferBuffer = undefined;

pub fn deinit() void {
    if (texture_transfer) |transfer_buffer| {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);
    }
    if (buffer_transfer) |transfer_buffer| {
        c.SDL_ReleaseGPUTransferBuffer(device, transfer_buffer);
    }
    for (depth_targets) |texture| {
        c.SDL_ReleaseGPUTexture(device, texture);
    }
    for (color_targets) |texture| {
        c.SDL_ReleaseGPUTexture(device, texture);
    }
    for (textures) |texture| {
        c.SDL_ReleaseGPUTexture(device, texture);
    }
    for (pipelines) |pipeline| {
        c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    }
    c.SDL_ReleaseGPUTexture(device, output_buffer);
    for (samplers) |sampler| {
        c.SDL_ReleaseGPUSampler(device, sampler);
    }
    for (buffers) |buffer| {
        c.SDL_ReleaseGPUBuffer(device, buffer);
    }

    // TODO: https://github.com/ziglang/zig/issues/25026
    // if (builtin.mode == .Debug) {
    //     _ = debug_allocator.detectLeaks();
    // }
}

fn resolveTextureFormat(format: TextureFormat) c.SDL_GPUTextureFormat {
    return switch (format) {
        .swapchain => c.SDL_GetGPUSwapchainTextureFormat(
            device,
            window,
        ),
        else => @intFromEnum(format),
    };
}

fn initPipeline(comptime key: PipelineKey) !*c.SDL_GPUGraphicsPipeline {
    const pipeline = key.pipeline;
    const vert = try shader.loadShader(gpa, device, pipeline.vert, key.vert_info);
    defer c.SDL_ReleaseGPUShader(device, vert);
    const frag = try shader.loadShader(gpa, device, pipeline.frag, key.frag_info);
    defer c.SDL_ReleaseGPUShader(device, frag);

    var color_target_descs: [PipelineKey.max_color_targets]c.SDL_GPUColorTargetDescription = undefined;
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

    log.debug("Initializing vert: {s}, frag: {s}", .{
        pipeline.vert,
        pipeline.frag,
    });

    inline for (.{ "vertex", "instance" }) |buffer_type| {
        comptime var upper: [buffer_type.len]u8 = undefined;
        comptime for (buffer_type, &upper) |src, *dst| {
            dst.* = std.ascii.toUpper(src);
        };
        const field_name = buffer_type ++ "_layout";
        const layout_name = comptime @field(pipeline, field_name) orelse continue;
        const layout_idx = @intFromEnum(@field(BufferLayoutEnum, layout_name));

        log.debug("    {s} layout: {s} ({})", .{
            buffer_type,
            layout_name,
            layout_idx,
        });

        buffer_descs[num_buffers] = .{
            .slot = num_buffers,
            .pitch = layout_pitch[layout_idx],
            .input_rate = @field(c, "SDL_GPU_VERTEXINPUTRATE_" ++ upper),
            .instance_step_rate = 0,
        };

        const layout = config.layouts[layout_idx];
        var offset: u32 = 0;
        for (layout.format, layout.location) |format, location| {
            attribs[num_attribs] = .{
                .location = location,
                .buffer_slot = num_buffers,
                .format = @intFromEnum(format),
                .offset = offset,
            };
            offset += types.vertexFormatLen(format);
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
        .rasterizer_state = .{
            .fill_mode = c.SDL_GPU_FILLMODE_FILL,
            .cull_mode = c.SDL_GPU_CULLMODE_BACK,
            .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            .enable_depth_clip = true,
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
            .color_target_descriptions = &color_target_descs,
            .depth_stencil_format = @intFromEnum(key.depth_target orelse
                TextureFormat.invalid),
            .has_depth_stencil_target = key.depth_target != null,
        },
        .props = 0,
    }));
}

fn initTextures(copy_pass: *c.SDL_GPUCopyPass) !u32 {
    // Gather texture initialization metadata
    inline for (config.textures, &texture_infos) |name, *info| {
        info.* = try @field(script, "initTexture" ++ name)();
    }

    // Initialize textures and transfer buffer
    var init_transfer_buffer_size: u32 = 0;
    var update_transfer_buffer_size: u32 = 0;
    inline for (
        config.textures,
        texture_infos,
        &textures,
        &texture_sizes,
    ) |name, info, *texture, *size| {
        size.* = c.SDL_CalculateGPUTextureFormatSize(
            @intFromEnum(info.format),
            info.width,
            info.height,
            info.depth,
        );
        texture.* =
            try sdlerr(c.SDL_CreateGPUTexture(device, &.{
                .type = @intFromEnum(info.tex_type),
                .format = @intFromEnum(info.format),
                .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                .width = info.width,
                .height = info.height,
                .layer_count_or_depth = info.depth,
                .num_levels = info.mip_levels,
                .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            }));
        errdefer c.SDL_ReleaseGPUTexture(device, texture.*);
        if (info.initFn != null) {
            init_transfer_buffer_size += size.*;
        }
        if (@hasDecl(script, "updateTexture" ++ name)) {
            update_transfer_buffer_size += size.*;
        }
    }
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
    for (texture_infos, texture_sizes) |info, size| {
        const initFn = info.initFn orelse continue;
        initFn(info, tbp[0..size]);
        tbp += size;
    }
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    // Record transfer buffer uploads to textures
    var offset: u32 = 0;
    for (texture_infos, textures, texture_sizes) |info, texture, size| {
        if (info.initFn == null) continue;
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
        offset += size;
    }

    return update_transfer_buffer_size;
}

fn initBuffers(copy_pass: *c.SDL_GPUCopyPass) !u32 {
    // Gather buffer initialization metadata
    inline for (config.buffers, &buffer_infos) |name, *info| {
        info.* = try @field(script, "initBuffer" ++ name)();
    }

    // Initialize buffers and transfer buffer
    var init_transfer_buffer_size: u32 = 0;
    var update_transfer_buffer_size: u32 = 0;
    inline for (
        config.buffers,
        buffer_infos,
        &buffers,
        &buffer_sizes,
    ) |name, info, *buffer, *size| {
        const element_size = layout_pitch[@intFromEnum(info.layout)];
        size.* = info.elements * element_size;
        buffer.* = try sdlerr(c.SDL_CreateGPUBuffer(device, &.{
            .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
            .size = size.*,
        }));
        errdefer c.SDL_ReleaseGPUBuffer(device, buffer.*);
        if (info.initFn != null) {
            init_transfer_buffer_size += size.*;
        }
        if (@hasDecl(script, "updateBuffer" ++ name)) {
            update_transfer_buffer_size += size.*;
        }
    }
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
    for (&buffer_infos, buffer_sizes) |*info, size| {
        const initFn = info.initFn orelse continue;
        const element_size = layout_pitch[@intFromEnum(info.layout)];
        info.elements = initFn(info.*, element_size, tbp[0..size]);
        tbp += size;
    }
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    // Record transfer buffer uploads to buffers
    var offset: u32 = 0;
    for (buffer_infos, buffers, buffer_sizes) |info, buffer, size| {
        if (info.initFn == null) continue;
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
        offset += size;
    }

    return update_transfer_buffer_size;
}

pub fn init(win: *c.SDL_Window, dev: *c.SDL_GPUDevice) !void {
    errdefer |e| log.err("{s}", .{@errorName(e)});

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

    // Pass gpa to script
    script.init(gpa);

    // Start copy pass
    const cmdbuf = c.SDL_AcquireGPUCommandBuffer(device);
    const copy_pass = c.SDL_BeginGPUCopyPass(cmdbuf).?;

    // Initialize textures and runtime transfer buffer
    const texture_transfer_size = try initTextures(copy_pass);
    if (texture_transfer_size > 0) {
        texture_transfer = try sdlerr(c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = texture_transfer_size,
        }));
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, texture_transfer);
    } else {
        texture_transfer = null;
    }

    // Initialize buffers and runtime transfer buffer
    const buffer_transfer_size = try initBuffers(copy_pass);
    if (buffer_transfer_size > 0) {
        buffer_transfer = try sdlerr(c.SDL_CreateGPUTransferBuffer(device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = buffer_transfer_size,
        }));
        errdefer c.SDL_ReleaseGPUTransferBuffer(device, buffer_transfer);
    } else {
        buffer_transfer = null;
    }

    // Submit copy pass
    c.SDL_EndGPUCopyPass(copy_pass);
    try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));

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
        errdefer c.SDL_ReleaseGPUSampler(device, sampler.*);
    }

    output_buffer =
        try sdlerr(c.SDL_CreateGPUTexture(device, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = resolveTextureFormat(.swapchain),
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
            .width = width,
            .height = height,
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        }));
    errdefer c.SDL_ReleaseGPUTexture(device, output_buffer);

    for (config.color_targets, &color_targets) |tex, *texture| {
        texture.* =
            try sdlerr(c.SDL_CreateGPUTexture(device, &.{
                .type = c.SDL_GPU_TEXTURETYPE_2D,
                .format = resolveTextureFormat(tex.format),
                .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
                .width = main_config.width * tex.p / tex.q,
                .height = main_config.height * tex.p / tex.q,
                .layer_count_or_depth = 1,
                .num_levels = 1,
                .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            }));
        errdefer c.SDL_ReleaseGPUTexture(texture.*);
    }

    for (config.depth_targets, &depth_targets) |tex, *texture| {
        texture.* =
            try sdlerr(c.SDL_CreateGPUTexture(device, &.{
                .type = c.SDL_GPU_TEXTURETYPE_2D,
                .format = resolveTextureFormat(tex.format),
                .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
                .width = main_config.width * tex.p / tex.q,
                .height = main_config.height * tex.p / tex.q,
                .layer_count_or_depth = 1,
                .num_levels = 1,
                .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
                .props = 0,
            }));
        errdefer c.SDL_ReleaseGPUTexture(texture.*);
    }

    inline for (pipeline_set.keys, &pipelines) |key, *pipeline| {
        pipeline.* = try initPipeline(key);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline.*);
    }
}

fn updateTextures(copy_pass: *c.SDL_GPUCopyPass, time: f32) !void {
    // Map transfer buffer
    const transfer_buffer = texture_transfer orelse return;
    var tbp: [*]u8 = @ptrCast(try sdlerr(c.SDL_MapGPUTransferBuffer(
        device,
        transfer_buffer,
        true,
    )));

    // Populate transfer buffer with data
    inline for (config.textures, texture_sizes) |name, size| {
        if (!@hasDecl(script, "updateTexture" ++ name)) continue;
        @field(script, "updateTexture" ++ name)(time, tbp[0..size]);
        tbp += size;
    }
    c.SDL_UnmapGPUTransferBuffer(device, transfer_buffer);

    // Record upload commands
    var offset: u32 = 0;
    inline for (
        config.textures,
        textures,
        texture_infos,
        texture_sizes,
    ) |name, texture, info, size| {
        if (!@hasDecl(script, "updateTexture" ++ name)) continue;
        c.SDL_UploadToGPUTexture(copy_pass, &.{
            .transfer_buffer = transfer_buffer,
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
        offset += size;
    }
}

fn updateBuffers(copy_pass: *c.SDL_GPUCopyPass, time: f32) !void {
    // Map transfer buffer
    const transfer_buffer = buffer_transfer orelse return;
    var tbp: [*]u8 = @ptrCast(try sdlerr(c.SDL_MapGPUTransferBuffer(
        device,
        transfer_buffer,
        true,
    )));

    // Populate transfer buffer with data
    inline for (config.buffers, buffer_sizes) |name, size| {
        if (!@hasDecl(script, "updateTexture" ++ name)) continue;
        @field(script, "updateTexture" ++ name)(time, tbp[0..size]);
        tbp += size;
    }

    // Record upload commands
    var offset: u32 = 0;
    inline for (config.buffers, buffers, buffer_sizes) |name, buffer, size| {
        if (!@hasDecl(script, "updateTexture" ++ name)) continue;
        c.SDL_UploadToGPUBuffer(copy_pass, &.{
            .transfer_buffer = transfer_buffer,
            .offset = offset,
        }, &.{
            .buffer = buffer,
            .offset = 0,
            .size = .size,
        }, true);
        offset += size;
    }
}

fn renderGraph(
    comptime active_clip: script.Clip,
    cmdbuf: *c.SDL_GPUCommandBuffer,
    swapchain_texture: *c.SDL_GPUTexture,
    swapchain_viewport: *const c.SDL_GPUViewport,
    resolution_match: bool,
) !void {
    pass_loop: inline for (config.passes) |pass| {
        // Filter pass by clip id list
        const pass_visible = comptime blk: {
            if (pass.condition) |clip_ids| {
                break :blk std.mem.containsAtLeastScalar(
                    script.Clip,
                    clip_ids,
                    1,
                    active_clip,
                );
            }
            break :blk true;
        };

        if (!pass_visible) continue :pass_loop;

        // Initialize color target infos
        const color_target_infos = blk: {
            var infos: [pass.color_targets.len]c.SDL_GPUColorTargetInfo = undefined;
            for (pass.color_targets, &infos) |target, *info| {
                info.* = .{
                    .texture = switch (target.target) {
                        .index => |index| color_targets[index],
                        .swapchain => if (resolution_match)
                            swapchain_texture
                        else
                            output_buffer,
                    },
                    .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                    .load_op = @intFromEnum(target.load_op),
                    .store_op = @intFromEnum(target.store_op),
                    .cycle = target.load_op != .load,
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
            cmdbuf,
            1,
            @ptrCast(&fragment_pass_uniforms),
            @sizeOf(@TypeOf(fragment_pass_uniforms)),
        );

        // Begin render pass
        const render_pass = c.SDL_BeginGPURenderPass(
            cmdbuf,
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
        if (target_swapchain and resolution_match) {
            c.SDL_SetGPUViewport(render_pass, swapchain_viewport);
        }

        // Record drawcalls
        draw_loop: inline for (pass.drawcalls) |drawcall| {
            // Filter drawcall by clip id list
            const drawcall_visible = comptime blk: {
                if (drawcall.condition) |clip_ids| {
                    break :blk std.mem.containsAtLeastScalar(
                        script.Clip,
                        clip_ids,
                        1,
                        active_clip,
                    );
                }
                break :blk true;
            };

            if (!drawcall_visible) continue :draw_loop;

            // Bind vertex buffer, storing number of instances to draw
            var num_buffers: u32 = 0;
            var num_vertices: u32 = switch (drawcall.num_vertices) {
                .num => |n| n,
                .infer => 3,
            };
            if (drawcall.vertex_buffer) |name| {
                const idx = @intFromEnum(@field(BufferEnum, name));
                c.SDL_BindGPUVertexBuffers(
                    render_pass,
                    num_buffers,
                    &.{ .buffer = buffers[idx], .offset = 0 },
                    1,
                );
                num_buffers += 1;
                if (drawcall.num_vertices == .infer) {
                    num_vertices = buffer_infos[idx].elements;
                }
            }

            // Bind instance buffer, storing number of instances to draw
            var num_instances: u32 = switch (drawcall.num_instances) {
                .num => |n| n,
                .infer => 1,
            };
            if (drawcall.instance_buffer) |name| {
                const idx = @intFromEnum(@field(BufferEnum, name));
                c.SDL_BindGPUVertexBuffers(
                    render_pass,
                    num_buffers,
                    &.{ .buffer = buffers[idx], .offset = 0 },
                    1,
                );
                num_buffers += 1;
                if (drawcall.num_instances == .infer) {
                    num_instances = buffer_infos[idx].elements;
                }
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
                    const reference = comptime schema.parseIndex(tex.texture) catch |e|
                        @compileError(std.fmt.comptimePrint("{s}", .{@errorName(e)}));
                    stage.bind(render_pass, @intCast(slot), &.{
                        .texture = if (reference) |result|
                            @field(@This(), result.ref)[result.idx]
                        else
                            textures[@intFromEnum(@field(TextureEnum, tex.texture))],
                        .sampler = samplers[@intFromEnum(@field(SamplerEnum, tex.sampler))],
                    }, 1);
                }
            }

            inline for (drawcall.pipelines) |pipeline| {
                // Find matching pipeline index from pipeline_keys at compile time
                const pipeline_key = comptime PipelineKey.init(pass, drawcall, pipeline);
                const pipeline_index = comptime pipeline_set.getIndex(pipeline_key);
                c.SDL_BindGPUGraphicsPipeline(render_pass, pipelines[pipeline_index]);
                c.SDL_DrawGPUPrimitives(
                    render_pass,
                    num_vertices,
                    num_instances,
                    drawcall.first_vertex,
                    drawcall.first_instance,
                );
            }
        }

        c.SDL_EndGPURenderPass(render_pass);
    }
}

pub fn render(time: f32) !void {
    errdefer |e| log.err("{s}", .{@errorName(e)});

    // Acquire command buffer
    const cmdbuf = try sdlerr(c.SDL_AcquireGPUCommandBuffer(device));
    errdefer _ = c.SDL_CancelGPUCommandBuffer(cmdbuf);

    // Update dynamic buffers
    const copy_pass = c.SDL_BeginGPUCopyPass(cmdbuf).?;
    try updateTextures(copy_pass, time);
    try updateBuffers(copy_pass, time);
    c.SDL_EndGPUCopyPass(copy_pass);

    // Update frame uniforms
    const frame_data = script.updateFrame(time);
    c.SDL_PushGPUVertexUniformData(
        cmdbuf,
        0,
        @ptrCast(&frame_data.vertex),
        @sizeOf(@TypeOf(frame_data.vertex)),
    );
    c.SDL_PushGPUFragmentUniformData(
        cmdbuf,
        0,
        @ptrCast(&frame_data.fragment),
        @sizeOf(@TypeOf(frame_data.fragment)),
    );
    // Reminder, per shader uniform counts are hardcoded at shader creation:
    comptime std.debug.assert(schema.num_vertex_uniform_buffers == 1);
    comptime std.debug.assert(schema.num_fragment_uniform_buffers == 2);

    // Acquire swapchain texture
    var swapchain_width: u32 = 0;
    var swapchain_height: u32 = 0;
    const swapchain_texture = blk: {
        var swapchain_texture: ?*c.SDL_GPUTexture = undefined;
        try sdlerr(c.SDL_WaitAndAcquireGPUSwapchainTexture(
            cmdbuf,
            window,
            &swapchain_texture,
            &swapchain_width,
            &swapchain_height,
        ));
        break :blk swapchain_texture orelse {
            try sdlerr(c.SDL_CancelGPUCommandBuffer(cmdbuf));
            return;
        };
    };
    const resolution_match =
        (swapchain_width == main_config.width and swapchain_height >= main_config.height) or
        (swapchain_height == main_config.height and swapchain_width >= main_config.width);

    // Compute viewport preserving aspect ratio rendering to swapchain
    const swapchain_viewport = viewport(swapchain_width, swapchain_height);

    // Render passes
    switch (frame_data.clip) {
        inline else => |active_clip| try renderGraph(
            active_clip,
            cmdbuf,
            swapchain_texture,
            &swapchain_viewport,
            resolution_match,
        ),
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

fn viewport(target_width: u32, target_height: u32) c.SDL_GPUViewport {
    const width_f32: f32 = @floatFromInt(target_width);
    const height_f32: f32 = @floatFromInt(target_height);
    const aspect_ratio = width_f32 / height_f32;

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

    const prefix = "[DYN] " ++ @tagName(level) ++
        if (scope == std.log.default_log_scope)
            ""
        else
            ("(" ++ @tagName(scope) ++ ")") ++
                ": ";

    const msg = std.fmt.bufPrint(&buf, prefix ++ format, args) catch blk: {
        break :blk "Log message too long";
    };

    print(msg.ptr, msg.len);
}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .err,
    .logFn = if (options.render_dynlib) myLogFn else std.log.defaultLog,
};
