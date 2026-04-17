//! Loading, unloading and calling into librender.so
const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @import("c");
const engine = @import("engine");
const sdlerr = engine.err.sdlerr;

const filename = "librender.so";
const log = std.log.scoped(.dynlib);
var dynlib: ?std.DynLib = null;
var init_ok: bool = false;
var window: *c.SDL_Window = undefined;
var device: *c.SDL_GPUDevice = undefined;
var api: struct {
    deinit: *const fn () callconv(.c) void,
    init: *const fn (
        *const Allocator,
        *c.SDL_Window,
        *c.SDL_GPUDevice,
    ) callconv(.c) bool,
    render: *const fn () callconv(.c) bool,
    pause: *const fn (bool) callconv(.c) void,
    isPaused: *const fn () callconv(.c) bool,
    seek: *const fn (f32) callconv(.c) void,
    getTime: *const fn () callconv(.c) f32,
} = undefined;

pub fn deinit() void {
    if (init_ok) {
        api.deinit();
    }
    init_ok = false;
}

pub fn init(
    arena: *const Allocator,
    win: *c.SDL_Window,
    dev: *c.SDL_GPUDevice,
) !void {
    window = win;
    device = dev;
    load() catch |e| {
        init_ok = false;
        log.err("{}", .{e});
        return;
    };
    init_ok = api.init(arena, win, dev);
}

pub fn render() !void {
    if (!init_ok or !api.render()) {
        // Fill window red when render is not succeeding
        const cmdbuf = try sdlerr(c.SDL_AcquireGPUCommandBuffer(device));

        {
            errdefer _ = c.SDL_CancelGPUCommandBuffer(cmdbuf);

            var swapchain_texture_opt: ?*c.SDL_GPUTexture = null;

            try sdlerr(c.SDL_WaitAndAcquireGPUSwapchainTexture(
                cmdbuf,
                window,
                &swapchain_texture_opt,
                null,
                null,
            ));

            const swapchain_texture = swapchain_texture_opt orelse {
                _ = c.SDL_CancelGPUCommandBuffer(cmdbuf);
                return;
            };

            const render_pass = c.SDL_BeginGPURenderPass(cmdbuf, &.{
                .texture = swapchain_texture,
                .clear_color = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
                .load_op = c.SDL_GPU_LOADOP_CLEAR,
                .store_op = c.SDL_GPU_STOREOP_STORE,
            }, 1, null);
            c.SDL_EndGPURenderPass(render_pass);
        }

        try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));
    }
}

pub fn pause(state: bool) void {
    if (!init_ok) return;
    api.pause(state);
}

pub fn isPaused() bool {
    if (!init_ok) return true;
    return api.isPaused();
}

pub fn seek(to: f32) void {
    if (!init_ok) return;
    api.seek(to);
}

pub fn getTime() f32 {
    if (!init_ok) return 0;
    return api.getTime();
}

fn load() !void {
    if (dynlib != null) {
        unload();
    }

    // Open librender.so
    log.info("Loading {s}", .{filename});
    dynlib = try std.DynLib.open("librender.so");

    const api_fields = @typeInfo(@TypeOf(api)).@"struct".fields;

    // Lookup symbols
    inline for (api_fields) |field| {
        log.info("Lookup {s}", .{field.name});
        @field(api, field.name) = dynlib.?.lookup(
            @TypeOf(@field(api, field.name)),
            field.name,
        ) orelse return error.SymbolNotFound;
    }
}

fn unload() void {
    if (dynlib) |*dl| {
        dl.close();
    }
    dynlib = null;
}
