const std = @import("std");

pub const c = @import("c");
pub const options = @import("options");

pub const camera = @import("engine/camera.zig");
pub const err = @import("engine/err.zig");
pub const font = @import("engine/font.zig");
pub const math = @import("engine/math.zig");
pub const noise = @import("engine/noise.zig");
pub const resource = @import("engine/resource.zig");
pub const schema = @import("engine/schema.zig");
pub const timeline = @import("engine/timeline.zig");
pub const types = @import("engine/types.zig");
pub const udp = @import("engine/udp.zig");
pub const util = @import("engine/util.zig");

// Compile-time script API assertions
comptime {
    const script = @import("script");

    // Assert that timeline has a correct format
    const clip_track = script.config.timeline.clip_track;
    if (clip_track.len < 2) {
        @compileError("clip_track must contain at least a start and an end");
    }
    if (clip_track[0].t != 0) {
        @compileError("clip_track must start at 0");
    }
    if (!std.mem.eql(u8, clip_track[clip_track.len - 1].id, "end")) {
        @compileError("clip_track last clip's id must be \"end\"");
    }
    var previous_t = 0;
    for (script.config.timeline.clip_track) |clip| {
        if (clip.t < previous_t) {
            @compileError("clip_track time can't run backwards");
        }
        previous_t = clip.t;
    }

    // Assert that layouts are extern structs
    for (@typeInfo(script.layout).@"struct".decls) |decl| {
        if (@typeInfo(@field(script.layout, decl.name)).@"struct".layout != .@"extern") {
            @compileError(std.fmt.comptimePrint("Layout {s} is not extern", .{decl.name}));
        }
    }

    // Assert that SSBO layouts are extern structs
    for (@typeInfo(script.storage_buffer).@"struct".decls) |decl| {
        const ssbo = @field(script.storage_buffer, decl.name);
        if (@typeInfo(ssbo.Header).@"struct".layout != .@"extern") {
            @compileError(std.fmt.comptimePrint("{s}.Header is not extern", .{decl.name}));
        }
        if (ssbo.Element != void and @typeInfo(ssbo.Element).@"struct".layout != .@"extern") {
            @compileError(std.fmt.comptimePrint("{s}.Element is not extern", .{decl.name}));
        }
        if (@sizeOf(ssbo.Header) % 16 != 0) {
            @compileError(std.fmt.comptimePrint("{s}.Header size is not a multiple of 16", .{decl.name}));
        }
    }
}
