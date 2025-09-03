const root = @import("root");
const c = root.c;

var start: u64 = 0;
var offset: u64 = 0;
pub var paused: bool = false;

const ns_per_sec: f32 = @floatFromInt(c.SDL_NS_PER_SECOND);

fn getTimeNS() u64 {
    return if (paused) offset else (c.SDL_GetTicksNS() - start) + offset;
}

pub fn getTime() f32 {
    const ns_f32: f32 = @floatFromInt(getTimeNS());
    const sec = ns_f32 / ns_per_sec;
    return sec;
}

pub fn pause(state: bool) void {
    offset = getTimeNS();
    start = c.SDL_GetTicksNS();
    paused = state;
}

pub fn seek(to_sec: f32) void {
    offset = @intFromFloat(to_sec * ns_per_sec);
    start = c.SDL_GetTicksNS();
}
