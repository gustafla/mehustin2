const builtin = @import("builtin");
const root = @import("root");
const c = root.c;
const sdlerr = root.sdlerr;

pub const Renderer = struct {
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,

    pub fn init(window: *c.SDL_Window) !Renderer {
        const device = try sdlerr(c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV, builtin.mode == .Debug, null));
        try sdlerr(c.SDL_ClaimWindowForGPUDevice(device, window));

        return .{
            .window = window,
            .device = device,
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
