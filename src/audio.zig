const root = @import("root");
const c = root.c;

pub const Player = struct {
    vorbis: *c.stb_vorbis,

    pub fn deinit(self: Player) void {
        c.stb_vorbis_close(self.vorbis);
    }

    pub fn init(name: []const u8) !Player {
        var err = c.VORBIS__no_error;
        const path = root.config.dataFilePath(name);
        // TODO: Do this with zig io and memory?
        const vorbis = c.stb_vorbis_open_filename(path, &err, null) orelse return error.VorbisOpenFailed;
        return .{ .vorbis = vorbis };
    }
};
