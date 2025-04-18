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

        const frag = try shader.loadShader(alloc, "shader.frag");
        defer alloc.free(frag.data);
        // const pipeline = sdlerr(c.SDL_CreateGPUGraphicsPipeline(device, .{
        //     .fragment_shader = frag.data,
        // }));

        return .{
            .window = window,
            .device = device,
            .pipeline = undefined,
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
