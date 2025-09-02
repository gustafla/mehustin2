//! Loading, unloading and calling into librender.so
const std = @import("std");
const c = @import("root").c;
const sdlerr = @import("err.zig").sdlerr;

const filename = "librender.so";
const log = std.log.scoped(.dynlib);

var dynlib: ?std.DynLib = null;
var init_ok: bool = false;
var window: *c.SDL_Window = undefined;
var device: *c.SDL_GPUDevice = undefined;
var api: struct {
    deinit: *const fn () callconv(.c) void,
    init: *const fn (*c.SDL_Window, *c.SDL_GPUDevice) callconv(.c) bool,
    render: *const fn (f32) callconv(.c) bool,
} = undefined;

pub fn deinit() void {
    if (init_ok) {
        api.deinit();
    }
    init_ok = false;
}

pub fn init(win: *c.SDL_Window, dev: *c.SDL_GPUDevice) !void {
    window = win;
    device = dev;
    load() catch |e| {
        init_ok = false;
        log.err("{}", .{e});
        return;
    };
    init_ok = api.init(win, dev);
}

pub fn render(t: f32) !void {
    if (!init_ok or !api.render(t)) {
        // Fill window red when render is not succeeding
        const cmdbuf = try sdlerr(c.SDL_AcquireGPUCommandBuffer(device));
        errdefer _ = c.SDL_CancelGPUCommandBuffer(cmdbuf);
        const swapchain_texture = blk: {
            var swapchain_texture: ?*c.SDL_GPUTexture = undefined;
            try sdlerr(c.SDL_WaitAndAcquireGPUSwapchainTexture(
                cmdbuf,
                window,
                &swapchain_texture,
                null,
                null,
            ));
            break :blk swapchain_texture orelse {
                try sdlerr(c.SDL_CancelGPUCommandBuffer(cmdbuf));
                return;
            };
        };
        const render_pass = c.SDL_BeginGPURenderPass(cmdbuf, &.{
            .texture = swapchain_texture,
            .clear_color = .{ .r = 1, .g = 0, .b = 0, .a = 1 },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
        }, 1, null);
        c.SDL_EndGPURenderPass(render_pass);
        try sdlerr(c.SDL_SubmitGPUCommandBuffer(cmdbuf));
    }
}

fn load() !void {
    if (dynlib != null) {
        unload();
    }

    // Open librender.so
    log.info("Loading {s}", .{filename});
    dynlib = try std.DynLib.open("librender.so");

    // Lookup symbols
    inline for (@typeInfo(@TypeOf(api)).@"struct".fields) |field| {
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
