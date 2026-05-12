//! Loading, unloading and calling into librender.so
const std = @import("std");

const c = @import("c");
const engine = @import("engine");
const sdlerr = engine.err.sdlerr;

const filename = "librender.so";
const log = std.log.scoped(.dynlib);

var dynlib: ?std.DynLib = null;

var dynlib_ok: bool = false;
var state_ptr: *anyopaque = undefined;
var window: *c.SDL_Window = undefined;
var device: *c.SDL_GPUDevice = undefined;

var api: struct {
    // Full initialization and shutdown.
    deinit: *const fn (*anyopaque) callconv(.c) void,
    init: *const fn (*c.SDL_Window, *c.SDL_GPUDevice) callconv(.c) ?*anyopaque,

    // Partial unload/load across reloads.
    unload: *const fn (*anyopaque) callconv(.c) void,
    load: *const fn (*anyopaque) callconv(.c) bool,

    // Regular runtime functions.
    render: *const fn (*anyopaque) callconv(.c) bool,
    pause: *const fn (*anyopaque, bool) callconv(.c) void,
    isPaused: *const fn (*anyopaque) callconv(.c) bool,
    seek: *const fn (*anyopaque, f32) callconv(.c) void,
    getTime: *const fn (*anyopaque) callconv(.c) f32,
} = undefined;

pub fn deinit() void {
    if (dynlib_ok) {
        api.deinit(state_ptr);
    }
    dynlib_ok = false;
    dynlibUnload();
}

pub fn init(
    _: std.mem.Allocator, // Match render.zig interface, can't pass across ZCUs.
    win: *c.SDL_Window,
    dev: *c.SDL_GPUDevice,
) !void {
    window = win;
    device = dev;
    dynlibLoad() catch |e| {
        log.err("{}", .{e});
        return;
    };
    if (api.init(win, dev)) |ptr| {
        state_ptr = ptr;
        dynlib_ok = true;
    } else {
        dynlib_ok = false;
    }
}

pub fn reload() void {
    if (dynlib_ok) {
        api.unload(state_ptr);
    }
    const ptr_valid = dynlib_ok;
    dynlib_ok = false;
    dynlibUnload();
    dynlibLoad() catch |e| {
        log.err("{}", .{e});
        return;
    };
    if (ptr_valid) {
        dynlib_ok = api.load(state_ptr);
    } else {
        if (api.init(window, device)) |ptr| {
            state_ptr = ptr;
            dynlib_ok = true;
        }
    }
}

pub fn render() !void {
    if (dynlib_ok and api.render(state_ptr)) return;

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

pub fn pause(state: bool) void {
    if (!dynlib_ok) return;
    api.pause(state_ptr, state);
}

pub fn isPaused() bool {
    if (!dynlib_ok) return true;
    return api.isPaused(state_ptr);
}

pub fn seek(to: f32) void {
    if (!dynlib_ok) return;
    api.seek(state_ptr, to);
}

pub fn getTime() f32 {
    if (!dynlib_ok) return 0.0;
    return api.getTime(state_ptr);
}

fn dynlibUnload() void {
    if (dynlib) |*dl| {
        dl.close();
    }
    dynlib = null;
}

fn dynlibLoad() !void {
    if (dynlib != null) {
        dynlibUnload();
    }

    // Open librender.so
    log.info("Loading {s}", .{filename});
    dynlib = try std.DynLib.open(filename);

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
