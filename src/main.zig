const std = @import("std");
const builtin = @import("builtin");
pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_revision.h");
    @cDefine("SDL_MAIN_HANDLED", {});
    @cInclude("SDL3/SDL_main.h");
});
pub const render = @import("render.zig");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

pub const config: struct {
    width: u32,
    height: u32,
    data_dir: []const u8,
    shader_dir: []const u8,

    pub fn openDataFile(self: @This(), name: []const u8) !File {
        const BUF_SIZE = 64;
        var path_buf: [BUF_SIZE]u8 = undefined;
        const path_len = self.data_dir.len + 1 + name.len;
        if (path_len > BUF_SIZE) {
            return error.DataFilePathTooLong;
        }
        @memcpy(&path_buf, self.data_dir);
        path_buf[self.data_dir.len] = std.fs.path.sep;
        @memcpy(path_buf[self.data_dir.len + 1 .. path_len], name);
        return std.fs.cwd().openFile(path_buf[0..path_len], .{});
    }
} = @import("config.zon");

pub const sdl_log = std.log.scoped(.sdl);
pub const res_log = std.log.scoped(.res);

// Root globals
var initialized: bool = false;
pub var alloc: Allocator = undefined;
pub var window: *c.SDL_Window = undefined;
var renderer: render.Renderer = undefined;

fn sdlAppInit(argv: [][*:0]u8) !c.SDL_AppResult {
    _ = argv;

    const revision: [*:0]const u8 = c.SDL_GetRevision();
    sdl_log.debug("SDL runtime revision: {s}", .{revision});

    _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "wayland,x11");
    _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_WAYLAND_MODE_EMULATION, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_WAYLAND_MODE_SCALING, "stretch");
    try sdlerr(c.SDL_SetAppMetadata("Mehustin2", "2.0.0", "tech.mehu.mehustin2"));
    try sdlerr(c.SDL_Init(c.SDL_INIT_VIDEO));

    window = try sdlerr(c.SDL_CreateWindow("Mehu Demo", config.width, config.height, c.SDL_WINDOW_RESIZABLE));
    renderer = try render.Renderer.init(alloc, window);

    initialized = true;

    return c.SDL_APP_CONTINUE;
}

fn sdlAppIterate() !c.SDL_AppResult {
    try renderer.render();

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

    if (initialized) {
        renderer.deinit();
        c.SDL_DestroyWindow(window);
    } else @panic("sdlAppQuit called before sdlAppInit");
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
