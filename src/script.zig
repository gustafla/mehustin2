const std = @import("std");

const engine = @import("engine");
const c = engine.c;
const schema = engine.schema;
const types = engine.types;
const TextureInfo = types.TextureInfo;
const BufferInfo = types.BufferInfo;
const timeline = engine.timeline;
const util = engine.util;

pub const config = struct {
    pub const main = @import("config.zon");
    pub const render: schema.Render = @import("render.zon");
    pub const timeline: schema.Timeline = @import("timeline.zon");
};

var gpa: std.mem.Allocator = undefined;
var threaded_io: std.Io.Threaded = .init_single_threaded;
const io = threaded_io.io();

pub fn init(_gpa: std.mem.Allocator) void {
    gpa = _gpa;
}

pub const string = struct {
    pub var fps: []const u8 = "";
    pub var time: []const u8 = "";
};
pub const String = std.meta.DeclEnum(string);

pub const anchor = struct {};
pub const Anchor = std.meta.DeclEnum(anchor);

pub const frame = struct {
    pub var state: timeline.State = undefined;

    pub fn update(time: f32) timeline.State {
        state = timeline.resolve(time);

        // Update strings
        util.updateDebugStrings(state, &string.fps, &string.time);

        return state;
    }
};

pub const texture = struct {
    pub const font_atlas = timeline.FontAtlas(&io, &gpa);

    pub const noise = struct {
        pub fn create() !TextureInfo {
            return .{
                .format = .r8_unorm,
                .width = config.main.noise_size,
                .height = config.main.noise_size,
            };
        }

        pub fn updateData(dst: []u8) !void {
            for (0..config.main.noise_size) |y| {
                for (0..config.main.noise_size) |x| {
                    const scale = 0.5;
                    const hash = std.hash.int(@as(u32, @bitCast(frame.state.time)));
                    const noise_val = engine.noise.simplex2(
                        (@as(f32, @floatFromInt(x)) * scale) + @as(f32, @floatFromInt(hash & 0x7fff)),
                        (@as(f32, @floatFromInt(y)) * scale),
                    );
                    dst[y * config.main.noise_size + x] =
                        @intFromFloat((noise_val * 0.5 + 0.5) * 256);
                }
            }
        }
    };
};
pub const Texture = std.meta.DeclEnum(texture);

pub const layout = struct {
    pub const InstanceText = timeline.InstanceText;

    pub const VertexPos = extern struct {
        position: [3]f32,

        pub const locations = .{0};
    };
};

pub const buffer = struct {
    pub const text_instances = timeline.text_instances;
};
pub const Buffer = std.meta.DeclEnum(buffer);

pub const storage_buffer = struct {};
pub const StorageBuffer = std.meta.DeclEnum(storage_buffer);
