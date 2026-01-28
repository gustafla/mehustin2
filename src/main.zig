const std = @import("std");
const builtin = @import("builtin");

const config = @import("config.zon");
const options = @import("options");

const audio = @import("audio.zig");
const sdlerr = @import("err.zig").sdlerr;

pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
    @cDefine("STB_VORBIS_HEADER_ONLY", {});
    @cInclude("stb_vorbis.c");
});
// Render is defined as dynlib.zig or render.zig depending on build configuration
const render = if (options.render_dynlib)
    @import("dynlib.zig")
else
    @import("render.zig");

const sdl_log = std.log.scoped(.sdl);
const fps_log = std.log.scoped(.fps);
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
};

var window: *c.SDL_Window = undefined;
var device: *c.SDL_GPUDevice = undefined;
var frames: u32 = 0;
var fps_ticks: u64 = 0;
var fps_enabled: bool = false;
var step_frame: bool = false;

// Private SDL symbols for hacking wayland mode emulation
extern fn SDL_GetVideoDisplay(display: c.SDL_DisplayID) ?*anyopaque;
extern fn SDL_AddFullscreenDisplayMode(display: *anyopaque, mode: *const c.SDL_DisplayMode) bool;

inline fn pause() void {
    if (builtin.mode != .Debug) return;
    if (render.isPaused()) {
        audio.play() catch unreachable;
        render.pause(false);
        std.log.info("Playing", .{});
    } else {
        audio.pause() catch unreachable;
        render.pause(true);
        std.log.info("Paused", .{});
    }
}

// Helper for seeking the demo
inline fn seek(to_sec: f32) void {
    if (builtin.mode != .Debug) return;
    const normalized = @max(to_sec, 0);
    render.seek(normalized);
    audio.seek(normalized) catch unreachable;
    step_frame = true;
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

    // Configure GPU initialization properties
    const gpu_properties = try sdlerr(c.SDL_CreateProperties());
    defer c.SDL_DestroyProperties(gpu_properties);
    try sdlerr(c.SDL_SetBooleanProperty(gpu_properties, c.SDL_PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, builtin.mode == .Debug));
    try sdlerr(c.SDL_SetBooleanProperty(gpu_properties, c.SDL_PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true));
    try sdlerr(c.SDL_SetBooleanProperty(gpu_properties, c.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_CLIP_DISTANCE_BOOLEAN, false));
    try sdlerr(c.SDL_SetBooleanProperty(gpu_properties, c.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_DEPTH_CLAMPING_BOOLEAN, false));
    try sdlerr(c.SDL_SetBooleanProperty(gpu_properties, c.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_INDIRECT_DRAW_FIRST_INSTANCE_BOOLEAN, false));
    try sdlerr(c.SDL_SetBooleanProperty(gpu_properties, c.SDL_PROP_GPU_DEVICE_CREATE_FEATURE_ANISOTROPY_BOOLEAN, false));

    // Init GPU device & claim window
    device = try sdlerr(c.SDL_CreateGPUDeviceWithProperties(gpu_properties));
    InitStep.push(.device);
    try sdlerr(c.SDL_ClaimWindowForGPUDevice(device, window));
    InitStep.push(.claim_window);

    // Set swapchain parameters
    const present_mode = if (c.SDL_WindowSupportsGPUPresentMode(
        device,
        window,
        c.SDL_GPU_PRESENTMODE_MAILBOX,
    )) blk: {
        sdl_log.info("Using presentation mode MAILBOX", .{});
        break :blk @as(c.SDL_GPUPresentMode, c.SDL_GPU_PRESENTMODE_MAILBOX);
    } else blk: {
        sdl_log.info("Using presentation mode VSYNC", .{});
        break :blk @as(c.SDL_GPUPresentMode, c.SDL_GPU_PRESENTMODE_VSYNC);
    };
    try sdlerr(c.SDL_SetGPUSwapchainParameters(
        device,
        window,
        c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
        present_mode,
    ));

    // Init audio
    if (@hasField(@TypeOf(config), "audio")) {
        if (audio.init(std.heap.c_allocator, config.audio)) {
            InitStep.push(.audio);
        } else |err| {
            audio.log.warn("Can't play {s}: {}", .{ config.audio, err });
        }
    }

    // Init render
    try render.init(@ptrCast(window), @ptrCast(device));
    InitStep.push(.render);

    // Go fullscreen if release build
    if (builtin.mode != .Debug) {
        try fullscreen();
    }

    // Start audio and timer
    try audio.play();
    render.seek(0);

    return c.SDL_APP_CONTINUE;
}

fn sdlAppIterate() !c.SDL_AppResult {
    const is_paused = (builtin.mode == .Debug) and render.isPaused();

    // Save power when paused
    if (is_paused and !step_frame) {
        c.SDL_Delay(c.SDL_MS_PER_SECOND / 60);
        return c.SDL_APP_CONTINUE;
    }
    step_frame = false;

    try render.render();

    // Quit if done
    if (builtin.mode != .Debug and audio.at_end) {
        return c.SDL_APP_SUCCESS;
    }

    // Measure FPS
    if (builtin.mode == .Debug and fps_enabled) {
        frames += 1;
        const ticks = c.SDL_GetTicksNS();
        if (fps_ticks + c.SDL_NS_PER_SECOND < ticks) {
            fps_log.info("{} FPS", .{frames});
            fps_ticks = ticks;
            frames = 0;
        }
    }

    return c.SDL_APP_CONTINUE;
}

fn sdlAppEvent(event: *c.SDL_Event) !c.SDL_AppResult {
    switch (event.type) {
        c.SDL_EVENT_QUIT => {
            return c.SDL_APP_SUCCESS;
        },
        c.SDL_EVENT_KEY_DOWN => {
            switch (event.key.scancode) {
                c.SDL_SCANCODE_ESCAPE, c.SDL_SCANCODE_Q => return c.SDL_APP_SUCCESS,
                c.SDL_SCANCODE_F => if (builtin.mode == .Debug) {
                    const flags = c.SDL_GetWindowFlags(window);
                    if (flags & c.SDL_WINDOW_FULLSCREEN != 0) {
                        try sdlerr(c.SDL_SetWindowFullscreen(window, false));
                        try sdlerr(c.SDL_ShowCursor());
                    } else {
                        try fullscreen();
                    }
                },
                c.SDL_SCANCODE_SPACE => pause(),
                c.SDL_SCANCODE_LEFT => seek(render.getTime() - 1),
                c.SDL_SCANCODE_RIGHT => seek(render.getTime() + 1),
                c.SDL_SCANCODE_PAGEUP => seek(render.getTime() - 8),
                c.SDL_SCANCODE_PAGEDOWN => seek(render.getTime() + 8),
                c.SDL_SCANCODE_HOME => seek(0),
                c.SDL_SCANCODE_R => if (builtin.mode == .Debug) {
                    // Save runtime state
                    const paused = render.isPaused();
                    const time = render.getTime();

                    // Reload (the dynlib.zig handles loading transparently)
                    render.deinit();
                    try render.init(@ptrCast(window), @ptrCast(device));

                    // Restore state
                    render.seek(time);
                    render.pause(paused);

                    // Show update if paused
                    step_frame = true;
                },
                c.SDL_SCANCODE_GRAVE => if (builtin.mode == .Debug) {
                    fps_enabled = !fps_enabled;
                },
                else => |k| {
                    std.log.debug("Unhandled scancode 0x{X}", .{k});
                },
            }
        },
        c.SDL_EVENT_MOUSE_WHEEL => seek(render.getTime() - event.wheel.y),
        c.SDL_EVENT_WINDOW_FIRST...c.SDL_EVENT_WINDOW_LAST,
        => if (builtin.mode == .Debug) {
            step_frame = true;
        },
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
