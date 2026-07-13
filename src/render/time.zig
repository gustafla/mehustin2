const c = @import("c");
const options = @import("options");

var start: u64 = 0;
var offset: u64 = 0;
pub var paused: bool = false;
pub var raw_ns: u64 = 0;

const ns_per_sec: f32 = @floatFromInt(c.SDL_NS_PER_SECOND);

fn getNowNS() u64 {
    return if (options.fixed_fps) |_| raw_ns else c.SDL_GetTicksNS();
}

fn getTimeNS() u64 {
    return if (paused) offset else (raw_ns - start) + offset;
}

pub fn stepFrame() void {
    if (options.fixed_fps) |fps| {
        raw_ns += @as(u64, @intFromFloat(ns_per_sec / fps));
    } else {
        raw_ns = c.SDL_GetTicksNS();
    }
}

pub fn getTime() f32 {
    const ns_f32: f32 = @floatFromInt(getTimeNS());
    const sec = ns_f32 / ns_per_sec;
    return sec;
}

pub fn pause(state: bool) void {
    if (state == paused) return;
    offset = getTimeNS();
    paused = state;
    const now = getNowNS();
    start = now;
    raw_ns = now;
}

pub fn seek(to_sec: f32) void {
    offset = @intFromFloat(to_sec * ns_per_sec);
    const now = getNowNS();
    start = now;
    raw_ns = now;
}
