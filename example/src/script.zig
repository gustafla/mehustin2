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
};
pub const Texture = std.meta.DeclEnum(texture);

pub const layout = struct {
    pub const InstanceText = timeline.InstanceText;

    pub const VertexPosNormal = extern struct {
        position: [3]f32,
        normal: [3]f32,

        pub const locations = .{ 0, 1 };
    };
};

pub const buffer = struct {
    pub const text_instances = timeline.text_instances;

    pub const cube = struct {
        pub const Layout = layout.VertexPosNormal;

        const position: [3 * 3 * 12]f32 = .{
            -1, -1, 1,  1,  1,  1,  -1, 1,  1,
            -1, -1, 1,  1,  -1, 1,  1,  1,  1,
            1,  -1, 1,  1,  1,  -1, 1,  1,  1,
            1,  -1, 1,  1,  -1, -1, 1,  1,  -1,
            1,  -1, -1, -1, 1,  -1, 1,  1,  -1,
            1,  -1, -1, -1, -1, -1, -1, 1,  -1,
            -1, -1, -1, -1, 1,  1,  -1, 1,  -1,
            -1, -1, -1, -1, -1, 1,  -1, 1,  1,
            -1, 1,  1,  1,  1,  -1, -1, 1,  -1,
            -1, 1,  1,  1,  1,  1,  1,  1,  -1,
            -1, -1, 1,  -1, -1, -1, 1,  -1, -1,
            -1, -1, 1,  1,  -1, -1, 1,  -1, 1,
        };
        const normal: [3 * 3 * 12]f32 = .{
            0,  0,  1,  0,  0,  1,  0,  0,  1,
            0,  0,  1,  0,  0,  1,  0,  0,  1,
            1,  0,  0,  1,  0,  0,  1,  0,  0,
            1,  0,  0,  1,  0,  0,  1,  0,  0,
            0,  0,  -1, 0,  0,  -1, 0,  0,  -1,
            0,  0,  -1, 0,  0,  -1, 0,  0,  -1,
            -1, 0,  0,  -1, 0,  0,  -1, 0,  0,
            -1, 0,  0,  -1, 0,  0,  -1, 0,  0,
            0,  1,  0,  0,  1,  0,  0,  1,  0,
            0,  1,  0,  0,  1,  0,  0,  1,  0,
            0,  -1, 0,  0,  -1, 0,  0,  -1, 0,
            0,  -1, 0,  0,  -1, 0,  0,  -1, 0,
        };

        pub const num_elements = position.len / 3;

        pub fn init(dst: []Layout, _: *BufferInfo) !void {
            util.interleave(Layout, dst, .{ &position, &normal });
        }
    };
};
pub const Buffer = std.meta.DeclEnum(buffer);

pub const storage_buffer = struct {};
pub const StorageBuffer = std.meta.DeclEnum(storage_buffer);
