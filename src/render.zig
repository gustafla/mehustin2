const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const shader = @import("shader.zig");
const Allocator = std.mem.Allocator;
const c = root.c;
const sdlerr = root.sdlerr;

var device: *c.SDL_GPUDevice = undefined;
var pipeline: *c.SDL_GPUGraphicsPipeline = undefined;

pub fn deinit() void {
    c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
    c.SDL_DestroyGPUDevice(device);
}

pub fn init(alloc: Allocator, window: *c.SDL_Window) !void {
    device = try sdlerr(c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, builtin.mode == .Debug, null));
    errdefer c.SDL_DestroyGPUDevice(device);
    try sdlerr(c.SDL_ClaimWindowForGPUDevice(device, window));

    const vert = try shader.loadShader(alloc, device, "quad.vert");
    defer c.SDL_ReleaseGPUShader(device, vert);
    const frag = try shader.loadShader(alloc, device, "shader.frag");
    defer c.SDL_ReleaseGPUShader(device, frag);

    const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, window);
    pipeline = try sdlerr(c.SDL_CreateGPUGraphicsPipeline(device, &std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
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
            .color_target_descriptions = &[_]c.SDL_GPUColorTargetDescription{.{ .format = swapchain_format }},
        },
    })));
    errdefer c.SDL_ReleaseGPUGraphicsPipeline(device, pipeline);
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
    c.SDL_BindGPUGraphicsPipeline(render_pass, pipeline);
    c.SDL_DrawGPUPrimitives(render_pass, 4, 1, 0, 0);
    c.SDL_EndGPURenderPass(render_pass);

    try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));
}
