const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
    @cDefine("STB_VORBIS_HEADER_ONLY", {});
    @cInclude("stb_vorbis.c");
});
const config = @import("config.zon");
const audio = @import("audio.zig");
const time = @import("time.zig");

const bps = if (@hasField(@TypeOf(config), "bpm")) config.bpm / 60 else 1;
const sdl_log = std.log.scoped(.sdl);
const sdlerr = @import("err.zig").sdlerr;

// Namespace for loading, unloading and calling into librender.so
const render_dynlib = struct {
    const filename = "librender.so";
    const log = std.log.scoped(.dynlib);

    var dynlib: ?std.DynLib = null;
    pub var deinit: *const fn () callconv(.c) void = undefined;
    pub var init: *const fn (*c.SDL_Window, *c.SDL_GPUDevice) callconv(.c) bool = undefined;
    pub var render: *const fn (f32) callconv(.c) bool = undefined;

    fn load() !void {
        if (dynlib != null) {
            unload();
        }

        // Open librender.so
        log.info("Loading {s}", .{filename});
        dynlib = std.DynLib.open("librender.so") catch |e| {
            std.debug.print("{s}\n", .{std.mem.span(std.c.dlerror() orelse return e)});
            return e;
        };

        // Lookup symbols
        inline for (@typeInfo(@This()).@"struct".decls) |decl| {
            log.info("Lookup {s}", .{decl.name});
            @field(@This(), decl.name) = dynlib.?.lookup(
                @TypeOf(@field(@This(), decl.name)),
                decl.name,
            ) orelse return error.SymbolNotFound;
        }
    }

    fn unload() void {
        if (dynlib) |*dl| {
            dl.close();
        }
        dynlib = null;
        @This().deinit = undefined;
        @This().init = undefined;
        @This().render = undefined;
    }
};

// Render is defined as render_dylib or imported directly depending on build configuration
const render = if (options.render_dynlib) render_dynlib else @import("render.zig");

// Track deinitialization with a stack
const InitStep = enum {
    window,
    device,
    claim_window,
    audio,
    render,

    const N = @typeInfo(@This()).@"enum".fields.len;
    var buffer = [_]InitStep{undefined} ** N;
    var stack: []InitStep = buffer[N..N];

    fn push(sys: InitStep) void {
        stack = buffer[N - stack.len - 1 ..];
        stack[0] = sys;
    }

    fn pop() void {
        stack = stack[1..];
    }

    fn peek() ?InitStep {
        if (stack.len == 0) return null;
        return stack[0];
    }
};

var window: *c.SDL_Window = undefined;
var device: *c.SDL_GPUDevice = undefined;

// Private SDL symbols for hacking wayland mode emulation
extern fn SDL_GetVideoDisplay(display: c.SDL_DisplayID) ?*anyopaque;
extern fn SDL_AddFullscreenDisplayMode(display: *anyopaque, mode: *const c.SDL_DisplayMode) bool;

inline fn pause() void {
    if (builtin.mode != .Debug) return;
    if (time.paused) {
        audio.play() catch unreachable;
        time.pause(false);
    } else {
        audio.pause() catch unreachable;
        time.pause(true);
    }
}

// Helper for seeking the demo
inline fn seek(to_sec: f32) void {
    if (builtin.mode != .Debug) return;
    const normalized = @max(to_sec, 0);
    time.seek(normalized);
    audio.seek(normalized) catch unreachable;
}

fn fullscreen() !void {
    try sdlerr(c.SDL_HideCursor());

    // Hack SDL Wayland mode emulation on Linux when static linking
    // This creates a video mode which matches the aspect ratio of the display,
    // but has a resolution as low as required in config.zon
    if (builtin.target.os.tag == .linux and !options.system_sdl) {
        if (std.mem.eql(u8, std.mem.span(c.SDL_GetCurrentVideoDriver()), "wayland")) {
            const display = c.SDL_GetDisplayForWindow(window);
            const mode = c.SDL_GetDesktopDisplayMode(display);
            const display_width: f32 = @floatFromInt(mode.*.w);
            const display_height: f32 = @floatFromInt(mode.*.h);
            const display_aspect = display_width / display_height;
            var width: u32 = config.width;
            var height: u32 = config.height;

            if (display_aspect > (@as(f32, config.width) / @as(f32, config.height))) {
                width = @intFromFloat(@as(f32, config.height) * display_aspect + 0.5);
            } else {
                height = @intFromFloat(@as(f32, config.width) / display_aspect + 0.5);
            }

            var hack_mode: c.SDL_DisplayMode = mode.*;
            hack_mode.w = @intCast(width);
            hack_mode.h = @intCast(height);

            const videodisplay = SDL_GetVideoDisplay(display) orelse return error.FullscreenHackFailed;
            _ = SDL_AddFullscreenDisplayMode(videodisplay, &hack_mode);
            try sdlerr(c.SDL_SetWindowFullscreenMode(window, &hack_mode));
        }
    }

    try sdlerr(c.SDL_SetWindowFullscreen(window, true));
}

fn sdlAppInit(argv: [][*:0]u8) !c.SDL_AppResult {
    _ = argv;

    // Init SDL
    const revision: [*:0]const u8 = c.SDL_GetRevision();
    sdl_log.debug("SDL runtime revision: {s}", .{revision});
    if (builtin.target.os.tag == .linux) {
        _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "wayland,x11");
        _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_WAYLAND_MODE_EMULATION, "1");
        _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_WAYLAND_MODE_SCALING, "stretch");
    }
    try sdlerr(c.SDL_SetAppMetadata("Mehustin2", "2.0.0", "tech.mehu.mehustin2"));
    try sdlerr(c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO));

    // Init window
    window = try sdlerr(c.SDL_CreateWindow("Mehu Demo", config.width, config.height, c.SDL_WINDOW_RESIZABLE));
    InitStep.push(.window);

    // Init GPU device & claim window
    device = try sdlerr(c.SDL_CreateGPUDevice(
        c.SDL_GPU_SHADERFORMAT_SPIRV,
        builtin.mode == .Debug,
        null,
    ));
    InitStep.push(.device);
    try sdlerr(c.SDL_ClaimWindowForGPUDevice(device, window));
    InitStep.push(.claim_window);

    // Init audio
    if (@hasField(@TypeOf(config), "audio")) {
        if (audio.init(std.heap.c_allocator, config.audio)) {
            InitStep.push(.audio);
        } else |err| {
            audio.log.warn("Can't play {s}: {}", .{ config.audio, err });
        }
    }

    // Init render
    blk: {
        if (options.render_dynlib) render.load() catch break :blk;
        if (render.init(@ptrCast(window), @ptrCast(device))) {
            InitStep.push(.render);
        } else if (!options.render_dynlib) return error.RenderInitFailed;
    }

    // Go fullscreen if release build
    if (builtin.mode != .Debug) {
        try fullscreen();
    }

    // Start audio and timer
    try audio.play();
    time.seek(0);

    return c.SDL_APP_CONTINUE;
}

fn sdlAppIterate() !c.SDL_AppResult {
    if (InitStep.peek() != .render or !render.render(time.getTime() * bps)) {
        if (!options.render_dynlib) {
            return error.RenderFailed;
        }

        // Paint window red when render is not succeeding
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
                return c.SDL_APP_CONTINUE;
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

    // Quit if done
    if (builtin.mode != .Debug and audio.at_end) {
        return c.SDL_APP_SUCCESS;
    }

    return c.SDL_APP_CONTINUE;
}

fn sdlAppEvent(event: *c.SDL_Event) !c.SDL_AppResult {
    switch (event.type) {
        c.SDL_EVENT_QUIT => {
            return c.SDL_APP_SUCCESS;
        },
        c.SDL_EVENT_KEY_DOWN => {
            switch (event.key.key) {
                c.SDLK_ESCAPE, c.SDLK_Q => return c.SDL_APP_SUCCESS,
                c.SDLK_F => if (builtin.mode == .Debug) {
                    const flags = c.SDL_GetWindowFlags(window);
                    if (flags & c.SDL_WINDOW_FULLSCREEN != 0) {
                        try sdlerr(c.SDL_SetWindowFullscreen(window, false));
                        try sdlerr(c.SDL_ShowCursor());
                    } else {
                        try fullscreen();
                    }
                },
                c.SDLK_SPACE => pause(),
                c.SDLK_LEFT => seek(time.getTime() - 1),
                c.SDLK_RIGHT => seek(time.getTime() + 1),
                c.SDLK_PAGEUP => seek(time.getTime() - 8),
                c.SDLK_PAGEDOWN => seek(time.getTime() + 8),
                c.SDLK_HOME => seek(0),
                c.SDLK_R => if (options.render_dynlib) {
                    if (InitStep.peek() == .render) {
                        render.deinit();
                        InitStep.pop();
                    }
                    blk: {
                        render.load() catch break :blk;
                        if (render.init(@ptrCast(window), @ptrCast(device))) {
                            InitStep.push(.render);
                        }
                    }
                },
                else => {},
            }
        },
        c.SDL_EVENT_MOUSE_WHEEL => seek(time.getTime() - event.wheel.y),
        else => {},
    }

    return c.SDL_APP_CONTINUE;
}

fn sdlAppQuit(result: anyerror!c.SDL_AppResult) void {
    _ = result catch |err| if (err == error.SdlError) {
        sdl_log.err("{s}", .{c.SDL_GetError()});
    };

    for (InitStep.stack) |sys| {
        switch (sys) {
            .window => c.SDL_DestroyWindow(window),
            .device => c.SDL_DestroyGPUDevice(device),
            .claim_window => c.SDL_ReleaseWindowFromGPUDevice(device, window),
            .audio => audio.deinit(),
            .render => render.deinit(),
        }
    }

    c.SDL_Quit();
}

pub fn main() !u8 {
    // Initialize error store
    app_err.reset();

    // Start SDL
    var empty_argv: [0:null]?[*:0]u8 = .{};
    const status: u8 = @truncate(@as(c_uint, @bitCast(c.SDL_RunApp(empty_argv.len, @ptrCast(&empty_argv), sdlMainC, null))));

    return app_err.load() orelse status;
}

fn sdlMainC(argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c_int {
    return c.SDL_EnterAppMainCallbacks(argc, @ptrCast(argv), sdlAppInitC, sdlAppIterateC, sdlAppEventC, sdlAppQuitC);
}

fn sdlAppInitC(appstate: ?*?*anyopaque, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c.SDL_AppResult {
    _ = appstate;
    return sdlAppInit(@ptrCast(argv.?[0..@intCast(argc)])) catch |err| app_err.store(err);
}

fn sdlAppIterateC(appstate: ?*anyopaque) callconv(.c) c.SDL_AppResult {
    _ = appstate;
    return sdlAppIterate() catch |err| app_err.store(err);
}

fn sdlAppEventC(appstate: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) c.SDL_AppResult {
    _ = appstate;
    return sdlAppEvent(event.?) catch |err| app_err.store(err);
}

fn sdlAppQuitC(appstate: ?*anyopaque, result: c.SDL_AppResult) callconv(.c) void {
    _ = appstate;
    sdlAppQuit(app_err.load() orelse result);
}

const ErrorStore = struct {
    const status_not_stored = 0;
    const status_storing = 1;
    const status_stored = 2;

    status: c.SDL_AtomicInt = .{},
    err: anyerror = undefined,
    trace_index: usize = undefined,
    trace_addrs: [32]usize = undefined,

    fn reset(es: *ErrorStore) void {
        _ = c.SDL_SetAtomicInt(&es.status, status_not_stored);
    }

    fn store(es: *ErrorStore, err: anyerror) c.SDL_AppResult {
        if (c.SDL_CompareAndSwapAtomicInt(&es.status, status_not_stored, status_storing)) {
            es.err = err;
            if (@errorReturnTrace()) |src_trace| {
                es.trace_index = src_trace.index;
                const len = @min(es.trace_addrs.len, src_trace.instruction_addresses.len);
                @memcpy(es.trace_addrs[0..len], src_trace.instruction_addresses[0..len]);
            }
            _ = c.SDL_SetAtomicInt(&es.status, status_stored);
        }
        return c.SDL_APP_FAILURE;
    }

    fn load(es: *ErrorStore) ?anyerror {
        if (c.SDL_GetAtomicInt(&es.status) != status_stored) return null;
        if (@errorReturnTrace()) |dst_trace| {
            dst_trace.index = es.trace_index;
            const len = @min(dst_trace.instruction_addresses.len, es.trace_addrs.len);
            @memcpy(dst_trace.instruction_addresses[0..len], es.trace_addrs[0..len]);
        }
        return es.err;
    }
};

var app_err: ErrorStore = .{};
