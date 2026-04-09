const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root");
const c = root.c;

const resource = @import("engine").resource;

const sdlerr = @import("../err.zig").sdlerr;

pub const log = std.log.scoped(.audio);

var vorbis: *c.stb_vorbis = undefined;
var audio: ?*c.SDL_AudioStream = null;
var info: c.stb_vorbis_info = undefined;
pub var at_end = false;

const bufsize = 1024 * 1024;
var buffer = [_]c_short{0} ** bufsize;

pub fn audioCallback(_: ?*anyopaque, _: ?*c.SDL_AudioStream, need_bytes: c_int, _: c_int) callconv(.c) void {
    const need_shorts = @divFloor(need_bytes, @sizeOf(c_short));
    var put_shorts: c_int = 0;
    var got_samples: c_int = 0;
    while (put_shorts < need_shorts) : (put_shorts += got_samples * info.channels) {
        got_samples = c.stb_vorbis_get_samples_short_interleaved(
            vorbis,
            info.channels,
            &buffer,
            @min(bufsize, need_shorts),
        );
        if (got_samples == 0) {
            at_end = true;
            return;
        }
        const len = got_samples * @sizeOf(c_short) * info.channels;
        sdlerr(c.SDL_PutAudioStreamData(audio, &buffer, len)) catch
            @panic("SDL_PutAudioStreamData failed");
    }
}

pub fn deinit() void {
    if (audio) |a| {
        c.SDL_DestroyAudioStream(a);
        c.stb_vorbis_close(vorbis);
    }
}

pub fn init(gpa: Allocator, name: []const u8) !void {
    // Open vorbis decoder
    var err = c.VORBIS__no_error;
    const path = try resource.dataFilePath(gpa, name);
    defer gpa.free(path);
    vorbis = c.stb_vorbis_open_filename(path, &err, null) orelse
        return error.VorbisOpenFailed;
    errdefer c.stb_vorbis_close(vorbis);
    info = c.stb_vorbis_get_info(vorbis);

    // Open audio device stream
    const spec: c.SDL_AudioSpec = .{
        .channels = info.channels,
        .format = c.SDL_AUDIO_S16,
        .freq = @intCast(info.sample_rate),
    };
    audio = try sdlerr(c.SDL_OpenAudioDeviceStream(
        c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
        &spec,
        audioCallback,
        vorbis,
    ));
}

pub fn pause() !void {
    if (audio) |a| {
        try sdlerr(c.SDL_PauseAudioStreamDevice(a));
    }
}

pub fn play() !void {
    if (audio) |a| {
        try sdlerr(c.SDL_ResumeAudioStreamDevice(a));
    }
}

pub fn seek(to_sec: f32) !void {
    if (audio) |a| {
        const num_samples = c.stb_vorbis_stream_length_in_samples(vorbis);
        const goal: c_uint = @intFromFloat(
            @as(f32, @floatFromInt(info.sample_rate)) * to_sec,
        );
        const samples = @min(num_samples, goal);
        try sdlerr(c.SDL_LockAudioStream(a));
        _ = c.stb_vorbis_seek(vorbis, samples);
        try sdlerr(c.SDL_UnlockAudioStream(a));
    }
}
