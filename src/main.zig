const std = @import("std");
const builtin = @import("builtin");
pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
    @cDefine("STB_VORBIS_HEADER_ONLY", {});
    @cInclude("stb_vorbis.c");
});
const util = @import("util.zig");
const render = @import("render.zig");
const audio = @import("audio.zig");
const time = @import("time.zig");

pub const sdl_log = std.log.scoped(.sdl);

// Track deinitialization with a stack
const Resource = enum {
    window,
    renderer,
    audio,

    const N = @typeInfo(@This()).@"enum".fields.len;
    var buffer = [_]Resource{undefined} ** N;
    var stack: []Resource = buffer[N..N];

    fn initialized(res: Resource) void {
        stack = buffer[N - stack.len - 1 ..];
        stack[0] = res;
    }
};

// Root globals
pub var alloc: std.mem.Allocator = undefined;
pub var window: *c.SDL_Window = undefined;

// Private SDL symbols for hacking wayland mode emulation
pub extern fn SDL_GetVideoDisplay(display: c.SDL_DisplayID) ?*anyopaque;
pub extern fn SDL_AddFullscreenDisplayMode(display: *anyopaque, mode: *const c.SDL_DisplayMode) bool;

fn fullscreen() !void {
    try sdlerr(c.SDL_HideCursor());

    if (std.mem.eql(u8, std.mem.span(c.SDL_GetCurrentVideoDriver()), "wayland")) {
        const display = c.SDL_GetDisplayForWindow(window);
        const mode = c.SDL_GetDesktopDisplayMode(display);
        const display_width: f32 = @floatFromInt(mode.*.w);
        const display_height: f32 = @floatFromInt(mode.*.h);
        const display_aspect = display_width / display_height;
        var width = util.conf.width;
        var height = util.conf.height;
        const render_width: f32 = @floatFromInt(width);
        const render_height: f32 = @floatFromInt(height);
        const render_aspect = render_width / render_height;

        if (display_aspect > render_aspect) {
            width = @intFromFloat(render_height * display_aspect + 0.5);
        } else {
            height = @intFromFloat(render_width / display_aspect + 0.5);
        }

        var hack_mode: c.SDL_DisplayMode = mode.*;
        hack_mode.w = @intCast(width);
        hack_mode.h = @intCast(height);

        const videodisplay = SDL_GetVideoDisplay(display) orelse return error.FullscreenHackFailed;
        _ = SDL_AddFullscreenDisplayMode(videodisplay, &hack_mode);
        try sdlerr(c.SDL_SetWindowFullscreenMode(window, &hack_mode));
    }

    try sdlerr(c.SDL_SetWindowFullscreen(window, true));
}

fn sdlAppInit(argv: [][*:0]u8) !c.SDL_AppResult {
    _ = argv;

    const revision: [*:0]const u8 = c.SDL_GetRevision();
    sdl_log.debug("SDL runtime revision: {s}", .{revision});

    _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "wayland,x11");
    _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_WAYLAND_MODE_EMULATION, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_WAYLAND_MODE_SCALING, "stretch");
    try sdlerr(c.SDL_SetAppMetadata("Mehustin2", "2.0.0", "tech.mehu.mehustin2"));
    try sdlerr(c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO));

    window = try sdlerr(c.SDL_CreateWindow("Mehu Demo", util.conf.width, util.conf.height, c.SDL_WINDOW_RESIZABLE));
    Resource.window.initialized();
    try render.init(alloc, window);
    Resource.renderer.initialized();
    try audio.init("music.ogg");
    Resource.audio.initialized();

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
    try render.render();

    // Quit if done
    return if (audio.at_end) c.SDL_APP_SUCCESS else c.SDL_APP_CONTINUE;
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
                    } else {
                        try fullscreen();
                    }
                },
                else => {},
            }
        },
        else => {},
    }

    return c.SDL_APP_CONTINUE;
}

fn sdlAppQuit(result: anyerror!c.SDL_AppResult) void {
    _ = result catch |err| if (err == error.SdlError) {
        sdl_log.err("{s}", .{c.SDL_GetError()});
    };

    for (Resource.stack) |res| {
        switch (res) {
            .window => c.SDL_DestroyWindow(window),
            .renderer => render.deinit(),
            .audio => audio.deinit(),
        }
    }

    c.SDL_Quit();
}

/// Converts the return value of an SDL function to an error union.
pub inline fn sdlerr(value: anytype) error{SdlError}!switch (@typeInfo(@TypeOf(value))) {
    .bool => void,
    .pointer, .optional => @TypeOf(value.?),
    .int => |info| switch (info.signedness) {
        .signed => @TypeOf(@max(0, value)),
        .unsigned => @TypeOf(value),
    },
    else => @compileError("unerrifiable type: " ++ @typeName(@TypeOf(value))),
} {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (!value) error.SdlError,
        .pointer, .optional => value orelse error.SdlError,
        .int => |info| switch (info.signedness) {
            .signed => if (value >= 0) @max(0, value) else error.SdlError,
            .unsigned => if (value != 0) value else error.SdlError,
        },
        else => comptime unreachable,
    };
}

pub fn main() !u8 {
    // Initialize error store
    app_err.reset();

    // Initialize allocator
    var debug_allocator: std.heap.DebugAllocator(.{}) = undefined;
    alloc = if (builtin.mode == .Debug) blk: {
        debug_allocator = std.heap.DebugAllocator(.{}).init;
        break :blk debug_allocator.allocator();
    } else std.heap.raw_c_allocator;
    defer if (builtin.mode == .Debug) {
        _ = debug_allocator.detectLeaks();
    };

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
