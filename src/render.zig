const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const shader = @import("shader.zig");
const util = @import("util.zig");
const math = @import("math.zig");
const Allocator = std.mem.Allocator;
const c = root.c;
const sdlerr = root.sdlerr;

// zig fmt: off
const shape = [_]f32{
    // position1    position2      position3
     0, -1,  0,     1,  0,  1,    -1,  0,  1, // lower front
     0, -1,  0,     1,  0, -1,     1,  0,  1, // lower right
     0, -1,  0,    -1,  0, -1,     1,  0, -1, // lower back
     0, -1,  0,    -1,  0, -1,    -1,  0,  1, // lower left

     0,  1,  0,    -1,  0,  1,     1,  0,  1, // upper front
     0,  1,  0,     1,  0,  1,     1,  0, -1, // upper right
     0,  1,  0,     1,  0, -1,    -1,  0, -1, // upper back
     0,  1,  0,    -1,  0, -1,    -1,  0,  1, // upper left
};
// zig fmt: on

const render_width: f32 = @floatFromInt(util.conf.width);
const render_height: f32 = @floatFromInt(util.conf.height);
const render_aspect = render_width / render_height;

var device: *c.SDL_GPUDevice = undefined;
var pipeline: *c.SDL_GPUGraphicsPipeline = undefined;
var pipeline3d: *c.SDL_GPUGraphicsPipeline = undefined;
var vertex_buffer: *c.SDL_GPUBuffer = undefined;

var perspective: math.Mat4 = undefined;
var view: math.Mat4 = undefined;

pub fn deinit() void {
    c.SDL_ReleaseGPUBuffer(device, vertex_buffer);
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline3d);
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    c.SDL_DestroyGPUDevice(device);
}

pub fn init(alloc: Allocator) !void {
    device = try sdlerr(c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, builtin.mode == .Debug, null));
    errdefer c.SDL_DestroyGPUDevice(device);
    try sdlerr(c.SDL_ClaimWindowForGPUDevice(device, root.window));

    const vert = try shader.loadShader(alloc, device, "quad.vert");
    defer c.SDL_ReleaseGPUShader(device, vert);
    const frag = try shader.loadShader(alloc, device, "shader.frag");
    defer c.SDL_ReleaseGPUShader(device, frag);

    const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, root.window);
    pipeline = try sdlerr(c.SDL_CreateGPUGraphicsPipeline(
        device,
        &std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
            .vertex_shader = vert,
            .fragment_shader = frag,
            // .vertex_input_state = .{
            //     .vertex_buffer_descriptions = 0,
            //     .num_vertex_buffers = 0,
            //     .vertex_attributes = .{},
            //     .num_vertex_attributes = 0
            // },
            .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP,
            .rasterizer_state = .{
                .fill_mode = c.SDL_GPU_FILLMODE_FILL,
                .cull_mode = c.SDL_GPU_CULLMODE_BACK,
                .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            },
            .multisample_state = .{
                .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            },
            .target_info = .{
                .num_color_targets = 1,
                .color_target_descriptions = &[_]c.SDL_GPUColorTargetDescription{
                    .{ .format = swapchain_format },
                },
            },
        }),
    ));
    errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);

    const vert3d = try shader.loadShader(alloc, device, "3d.vert");
    defer c.SDL_ReleaseGPUShader(device, vert3d);
    const frag3d = try shader.loadShader(alloc, device, "3d.frag");
    defer c.SDL_ReleaseGPUShader(device, frag3d);

    pipeline3d = try sdlerr(c.SDL_CreateGPUGraphicsPipeline(
        device,
        &std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
            .vertex_shader = vert3d,
            .fragment_shader = frag3d,
            .vertex_input_state = .{
                .vertex_buffer_descriptions = &[_]c.SDL_GPUVertexBufferDescription{
                    .{
                        .slot = 0,
                        .pitch = @sizeOf(f32) * 3,
                        .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                        .instance_step_rate = 0,
                    },
                },
                .num_vertex_buffers = 1,
                .vertex_attributes = &[_]c.SDL_GPUVertexAttribute{
                    .{
                        .location = 0,
                        .buffer_slot = 0,
                        .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
                        .offset = 0,
                    },
                },
                .num_vertex_attributes = 1,
            },
            .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP,
            .rasterizer_state = .{
                .fill_mode = c.SDL_GPU_FILLMODE_FILL,
                .cull_mode = c.SDL_GPU_CULLMODE_BACK,
                .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE,
            },
            .multisample_state = .{
                .sample_count = c.SDL_GPU_SAMPLECOUNT_1,
            },
            .target_info = .{
                .num_color_targets = 1,
                .color_target_descriptions = &[_]c.SDL_GPUColorTargetDescription{
                    .{ .format = swapchain_format },
                },
            },
        }),
    ));
    errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline3d);

    vertex_buffer = try sdlerr(c.SDL_CreateGPUBuffer(device, &c.SDL_GPUBufferCreateInfo{
        .size = @sizeOf(@TypeOf(shape)),
        .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
        .props = 0,
    }));

    const transferbuf = c.SDL_CreateGPUTransferBuffer(device, &c.SDL_GPUTransferBufferCreateInfo{
        .size = @sizeOf(@TypeOf(shape)),
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .props = 0,
    });
    defer c.SDL_ReleaseGPUTransferBuffer(device, transferbuf);
    const data: [*]f32 = @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(device, transferbuf, false)));
    @memcpy(data, &shape);
    c.SDL_UnmapGPUTransferBuffer(device, transferbuf);

    const cmdbuf = c.SDL_AcquireGPUCommandBuffer(device);
    const copy_pass = c.SDL_BeginGPUCopyPass(cmdbuf);
    c.SDL_UploadToGPUBuffer(
        copy_pass,
        &c.SDL_GPUTransferBufferLocation{
            .offset = 0,
            .transfer_buffer = transferbuf,
        },
        &c.SDL_GPUBufferRegion{
            .size = @sizeOf(@TypeOf(shape)),
            .offset = 0,
            .buffer = vertex_buffer,
        },
        false,
    );
    c.SDL_EndGPUCopyPass(copy_pass);
    try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));
}

pub fn render() !void {
    const cmdbuf = try sdlerr(c.SDL_AcquireGPUCommandBuffer(device));
    errdefer _ = c.SDL_CancelGPUCommandBuffer(cmdbuf);
    var width: u32 = 0;
    var height: u32 = 0;

    const swapchain_texture = blk: {
        var swapchain_texture: ?*c.SDL_GPUTexture = undefined;
        try sdlerr(c.SDL_WaitAndAcquireGPUSwapchainTexture(cmdbuf, root.window, &swapchain_texture, &width, &height));
        break :blk swapchain_texture orelse {
            try sdlerr(c.SDL_CancelGPUCommandBuffer(cmdbuf));
            return;
        };
    };

    const color_target_info = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
        .texture = swapchain_texture,
        .clear_color = .{ 0.0, 0.0, 0.0, 1.0 },
        .load_op = c.SDL_GPU_LOADOP_CLEAR,
        .store_op = c.SDL_GPU_STOREOP_STORE,
    });
    const render_pass = c.SDL_BeginGPURenderPass(cmdbuf, &color_target_info, 1, null);
    c.SDL_SetGPUViewport(render_pass, &viewport(width, height));

    // Background
    c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline);
    c.SDL_DrawGPUPrimitives(render_pass, 4, 1, 0, 0);

    // 3D scene
    c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline3d);
    c.SDL_BindGPUVertexBuffers(render_pass, 0, &[_]c.SDL_GPUBufferBinding{.{
        .buffer = vertex_buffer,
        .offset = 0,
    }}, 1);
    c.SDL_DrawGPUPrimitives(render_pass, shape.len / 3, 1, 0, 0);

    c.SDL_EndGPURenderPass(render_pass);

    try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));
}

fn viewport(width: u32, height: u32) c.SDL_GPUViewport {
    const width_f32: f32 = @floatFromInt(width);
    const height_f32: f32 = @floatFromInt(height);
    const aspect_ratio = width_f32 / height_f32;

    var viewport_width = width_f32;
    var viewport_height = height_f32;
    if (aspect_ratio > render_aspect) {
        viewport_width = height_f32 * render_aspect;
    } else {
        viewport_height = width_f32 / render_aspect;
    }

    return .{
        .x = if (aspect_ratio > render_aspect) (width_f32 - viewport_width) / 2 else 0,
        .y = if (aspect_ratio > render_aspect) 0 else (height_f32 - viewport_height) / 2,
        .w = viewport_width,
        .h = viewport_height,
        .min_depth = 0,
        .max_depth = 1,
    };
}
