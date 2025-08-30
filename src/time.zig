const root = @import("root");
const config = @import("config.zon");
const c = root.c;

var start: u64 = 0;
var offset: u64 = 0;
pub var paused: bool = false;

const ns_per_sec: f32 = @floatFromInt(c.SDL_NS_PER_SECOND);
const bps = if (@hasField(@TypeOf(config), "bpm")) config.bpm / 60 else 1;

fn getTimeNS() u64 {
    return if (paused) offset else (c.SDL_GetTicksNS() - start) + offset;
}

pub fn getTime() f32 {
    const ns_f32: f32 = @floatFromInt(getTimeNS());
    const sec = ns_f32 / ns_per_sec;
    return sec * bps;
}

pub fn pause(state: bool) void {
    offset = getTimeNS();
    start = c.SDL_GetTicksNS();
    paused = state;
}

pub fn seek(to: f32) void {
    offset = @intFromFloat((to / bps) * ns_per_sec);
    start = c.SDL_GetTicksNS();
}
