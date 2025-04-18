const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const shader = @import("shader.zig");
const Allocator = std.mem.Allocator;
const c = root.c;
const sdlerr = root.sdlerr;

pub const Renderer = struct {
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    pipeline: *c.SDL_GPUGraphicsPipeline,

    pub fn init(alloc: Allocator, window: *c.SDL_Window) !Renderer {
        const device = try sdlerr(c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, builtin.mode == .Debug, null));
        try sdlerr(c.SDL_ClaimWindowForGPUDevice(device, window));

        const vert = try shader.loadShader(alloc, device, "quad.vert");
        defer c.SDL_ReleaseGPUShader(device, vert);
        const frag = try shader.loadShader(alloc, device, "shader.frag");
        defer c.SDL_ReleaseGPUShader(device, frag);

        const swapchain_format = c.SDL_GetGPUSwapchainTextureFormat(device, window);
        const pipeline = try sdlerr(c.SDL_CreateGPUGraphicsPipeline(device, &std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
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

        return .{
            .window = window,
            .device = device,
            .pipeline = pipeline,
        };
    }

    pub fn deinit(self: Renderer) void {
        c.SDL_DestroyGPUDevice(self.device);
        c.SDL_DestroyWindow(self.window);
    }

    pub fn render(self: Renderer) !void {
        const cmdbuf = try sdlerr(c.SDL_AcquireGPUCommandBuffer(self.device));
        var swapchain_texture: ?*c.SDL_GPUTexture = undefined;
        var width: u32 = 0;
        var height: u32 = 0;
        try sdlerr(c.SDL_WaitAndAcquireGPUSwapchainTexture(cmdbuf, self.window, &swapchain_texture, &width, &height));
        if (swapchain_texture) |_| {
            // TODO: Render pass here
        }

        try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));
    }
};
