const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const config = @import("config.zon");
const shader = @import("shader.zig");
const res = @import("res.zig");
const math = @import("math.zig");
const time = @import("time.zig");
const Allocator = std.mem.Allocator;
const c = root.c;
const sdlerr = root.sdlerr;

const VertexAttributes = packed struct {
    coords: bool = false,
    normals: bool = false,
    colors: bool = false,
    uvs: bool = false,
};

const AttribFields = std.meta.FieldEnum(VertexAttributes);

fn attribParameters(comptime attribName: []const u8) ?struct {
    pitch: u32,
    format: c.SDL_GPUVertexElementFormat,
} {
    const field = std.meta.stringToEnum(AttribFields, attribName);
    return switch (field orelse return null) {
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
    R16g16b16a16Float = c.SDL_GPU_TEXTUREFORMAT_R16G16B16A16_FLOAT,
    Swapchain,
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
};

const UniformData = enum {
    Matrices,
    Shadertoy,
};

const ColorTarget = union(enum) {
    index: usize,
    swapchain,
};

const Shader = struct {
    name: []const u8,
    info: struct {
        num_samplers: u32 = 0,
        num_storage_textures: u32 = 0,
        num_storage_buffers: u32 = 0,
        num_uniform_buffers: u32 = 0,
    } = .{},
};

const Pipeline = struct {
    vert: Shader = .{ .name = "quad.vert" },
    frag: Shader,
    vertex_attributes: VertexAttributes = .{},
    primitive_type: PrimitiveType = .TriangleStrip,
    depth_test: ?struct {
        compare_op: CompareOp = .Less,
        enable: bool = true,
        write: bool = true,
    } = null,
    color_targets: []const ColorFormat = &.{.Swapchain},
    depth_target: ?DepthFormat = null,
};

const Texture = union(enum) {
    color: usize,
    // depth: usize,
};

const Pass = struct {
    drawcalls: []const struct {
        pipeline: usize,
        vertices: ?usize = null,
        vertex_samplers: []const Texture = &.{},
        fragment_samplers: []const Texture = &.{},
        vertex_uniforms: []const UniformData = &.{},
        fragment_uniforms: []const UniformData = &.{},
        num_vertices: union(enum) {
            infer, // From first binding coords count, or 4 if no bindings
            override: u32,
        } = .infer,
        num_instances: u32 = 1,
        first_vertex: u32 = 0,
        first_instance: u32 = 0,
    },
    viewport: enum {
        Default,
        ToWindow,
    } = .Default,
    color_targets: []const ColorTarget = &.{.swapchain},
    depth_target: ?usize = null,
};

const VertexSource = union(enum) {
    static: VertexData,
};

const Scene = struct {
    color_textures: []const ColorFormat = &.{},
    depth_textures: []const DepthFormat = &.{},
    pipelines: []const Pipeline,
    vertices: []const VertexSource,
    passes: []const Pass,
};

const scene: Scene = @import("scene.zon");

// Compute upper bounds from scene
fn maxSliceLen(set: anytype, comptime fieldName: []const u8) usize {
    var max: usize = 0;
    for (set) |elem| {
        const len = @field(elem, fieldName).len;
        if (len > max) {
            max = len;
        }
    }
    return max;
}
const max_pipeline_color_targets = maxSliceLen(scene.pipelines, "color_targets");
const max_pass_color_targets = maxSliceLen(scene.passes, "color_targets");

pub const render_width: f32 = @floatFromInt(config.width);
pub const render_height: f32 = @floatFromInt(config.height);
pub const render_aspect = render_width / render_height;

var device: *c.SDL_GPUDevice = undefined;
var nearest: *c.SDL_GPUSampler = undefined;
var color_textures: [scene.color_textures.len]*c.SDL_GPUTexture = undefined;
var depth_textures: [scene.depth_textures.len]*c.SDL_GPUTexture = undefined;
var pipelines: [scene.pipelines.len]*c.SDL_GPUGraphicsPipeline = undefined;
var vertex_buffers: [scene.vertices.len]VertexBuffers = undefined;
var vertex_counts: [scene.vertices.len]u32 = undefined;

pub fn deinit() void {
    for (vertex_buffers) |buf| {
        inline for (@typeInfo(VertexBuffers).@"struct".fields) |field| {
            c.SDL_ReleaseGPUBuffer(device, @field(buf, field.name));
        }
    }
    for (pipelines) |pipeline| {
        c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    }
    for (depth_textures) |texture| {
        c.SDL_ReleaseGPUTexture(device, texture);
    }
    for (color_textures) |texture| {
        c.SDL_ReleaseGPUTexture(device, texture);
    }
    c.SDL_ReleaseGPUSampler(device, nearest);
    c.SDL_DestroyGPUDevice(device);
}

pub fn initColorTexture(format: ColorFormat) !*c.SDL_GPUTexture {
    return try sdlerr(c.SDL_CreateGPUTexture(device, &.{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = switch (format) {
            .Swapchain => c.SDL_GetGPUSwapchainTextureFormat(
                device,
                root.window,
            ),
            else => @intFromEnum(format),
        },
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET,
        .width = render_width,
        .height = render_height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }));
}

pub fn initDepthTexture(format: DepthFormat) !*c.SDL_GPUTexture {
    return try sdlerr(c.SDL_CreateGPUTexture(device, &.{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = @intFromEnum(format),
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER | c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
        .width = render_width,
        .height = render_height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
        .props = 0,
    }));
}

fn initPipeline(alloc: Allocator, pipeline: Pipeline) !*c.SDL_GPUGraphicsPipeline {
    const vert = try shader.loadShader(alloc, device, pipeline.vert.name, pipeline.vert.info);
    defer c.SDL_ReleaseGPUShader(device, vert);
    const frag = try shader.loadShader(alloc, device, pipeline.frag.name, pipeline.frag.info);
    defer c.SDL_ReleaseGPUShader(device, frag);

    var color_targets: [max_pipeline_color_targets]c.SDL_GPUColorTargetDescription = undefined;
    for (pipeline.color_targets, color_targets[0..pipeline.color_targets.len]) |target_def, *target| {
        const format = switch (target_def) {
            .Swapchain => c.SDL_GetGPUSwapchainTextureFormat(
                device,
                root.window,
            ),
            else => @intFromEnum(target_def),
        };
        target.* = .{ .format = format };
    }

    // TODO: Instances
    const max_attribs = @bitSizeOf(VertexAttributes);
    var buffers: [max_attribs]c.SDL_GPUVertexBufferDescription = undefined;
    var attribs: [max_attribs]c.SDL_GPUVertexAttribute = undefined;
    var num_attribs: u32 = 0;
    inline for (@typeInfo(VertexAttributes).@"struct".fields, 0..) |field, i| {
        const param = attribParameters(field.name) orelse unreachable;
        const enabled = @field(pipeline.vertex_attributes, field.name);
        if (enabled) {
            buffers[num_attribs] = .{
                .slot = num_attribs,
                .pitch = param.pitch,
                .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                .instance_step_rate = 0,
            };
            attribs[num_attribs] = .{
                .location = @intCast(i),
                .buffer_slot = num_attribs,
                .format = param.format,
                .offset = 0,
            };
            num_attribs += 1;
        }
    }

    return try sdlerr(c.SDL_CreateGPUGraphicsPipeline(device, &.{
        .vertex_shader = vert,
        .fragment_shader = frag,
        .vertex_input_state = .{
            .vertex_buffer_descriptions = &buffers,
            .num_vertex_buffers = num_attribs,
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
            .num_color_targets = @as(u32, @intCast(pipeline.color_targets.len)),
            .color_target_descriptions = &color_targets,
            .depth_stencil_format = @intFromEnum(pipeline.depth_target orelse undefined),
            .has_depth_stencil_target = pipeline.depth_target != null,
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
    { // TODO: Remove this workaround when SDL is updated from 3.2.20
        var swapchain_texture: ?*c.SDL_GPUTexture = undefined;
        var width: u32 = undefined;
        var height: u32 = undefined;
        _ = c.SDL_AcquireGPUSwapchainTexture(
            cmdbuf,
            root.window,
            &swapchain_texture,
            &width,
            &height,
        );
    }
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

pub fn init(alloc: Allocator) !void {
    device = try sdlerr(c.SDL_CreateGPUDevice(
        c.SDL_GPU_SHADERFORMAT_SPIRV,
        builtin.mode == .Debug,
        null,
    ));
    errdefer c.SDL_DestroyGPUDevice(device);
    try sdlerr(c.SDL_ClaimWindowForGPUDevice(device, root.window));

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

    for (scene.color_textures, &color_textures) |format, *texture| {
        texture.* = try initColorTexture(format);
        errdefer c.SDL_ReleaseGPUTexture(texture.*);
    }

    for (scene.depth_textures, &depth_textures) |format, *texture| {
        texture.* = try initDepthTexture(format);
        errdefer c.SDL_ReleaseGPUTexture(texture.*);
    }

    for (scene.pipelines, &pipelines) |def, *pipeline| {
        pipeline.* = try initPipeline(alloc, def);
        errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline.*);
    }

    for (scene.vertices, &vertex_buffers, &vertex_counts) |def, *buffers, *count| {
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
}

pub fn render() !void {
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
            root.window,
            &swapchain_texture,
            &width,
            &height,
        ));
        break :blk swapchain_texture orelse {
            try sdlerr(c.SDL_CancelGPUCommandBuffer(cmdbuf));
            return;
        };
    };

    // Compute view & projection matrices
    const t = time.getTime();
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
            .{
                @sin(t / 4 * std.math.pi) * 3,
                @sin(t / 8 * std.math.pi) * 2,
                @cos(t / 3 * std.math.pi) * 4,
            },
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
        .time = t,
    };

    // Render passes
    for (scene.passes) |pass| {
        var color_target_infos: [max_pass_color_targets]c.SDL_GPUColorTargetInfo = undefined;
        for (pass.color_targets, color_target_infos[0..pass.color_targets.len]) |target, *info| {
            info.* = .{
                .texture = switch (target) {
                    .index => |index| color_textures[index],
                    .swapchain => swapchain_texture,
                },
                .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
                .cycle = true,
            };
        }
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
        switch (pass.viewport) {
            .Default => {},
            .ToWindow => c.SDL_SetGPUViewport(render_pass, &viewport(width, height)),
        }

        // Record drawcalls
        for (pass.drawcalls) |drawcall| {
            c.SDL_BindGPUGraphicsPipeline(render_pass, pipelines[drawcall.pipeline]);

            // Bind vertex buffers
            if (drawcall.vertices) |vertices_index| {
                var slot: u32 = 0;
                inline for (@typeInfo(VertexBuffers).@"struct".fields) |field| {
                    const buffer = @field(vertex_buffers[vertices_index], field.name);
                    if (buffer) |buf| {
                        c.SDL_BindGPUVertexBuffers(
                            render_pass,
                            slot,
                            &.{ .buffer = buf, .offset = 0 },
                            1,
                        );
                        slot += 1;
                    }
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
                for (stage.tex, 0..) |tex, slot| {
                    stage.bind(render_pass, @intCast(slot), &.{
                        .texture = switch (tex) {
                            .color => |i| color_textures[i],
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
                for (stage.ufms, 0..) |ufm, slot| {
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
                .infer => if (drawcall.vertices) |i| vertex_counts[i] else 4,
                .override => |num| num,
            };
            c.SDL_DrawGPUPrimitives(
                render_pass,
                num_vertices,
                drawcall.num_instances,
                drawcall.first_vertex,
                drawcall.first_instance,
            );
        }

        c.SDL_EndGPURenderPass(render_pass);
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
