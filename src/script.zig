const std = @import("std");
const Allocator = std.mem.Allocator;

const timeline: Timeline = @import("timeline.zon");

const math = @import("math.zig");
const render = @import("render.zig");
const types = @import("render/types.zig");
const resource = @import("resource.zig");
const camera = @import("script/camera.zig");
const font = @import("script/font.zig");
const noise_zig = @import("script/noise.zig");
const schema = @import("script/schema.zig");
const Timeline = schema.Timeline;
const ClipSegment = schema.ClipSegment;
const CameraSegment = schema.CameraSegment;
const util = @import("script/util.zig");
const config = @import("config.zon");

pub const Clip = schema.ClipEnum(timeline);
const clips = schema.clipTable(timeline)[0..].*;
const cam_fns = schema.camFnTable(timeline)[0..].*;
const cam_entries = schema.camEntryTable(timeline)[0..].*;

// ---- GLOBAL ----

var gpa: Allocator = undefined;

pub fn init(init_gpa: Allocator) void {
    gpa = init_gpa;
}

// ---- FRAME DATA (1st) ----

pub const frame = struct {
    pub const VertexData = extern struct {
        view_projection: math.Mat4,
        camera_position: [4]f32,
        time: f32,
    };

    pub const FragmentData = extern struct {
        sun_direction_intensity: [4]f32,
        sun_color_ambient: [4]f32,
        time: f32,
    };

    pub const State = struct {
        clip: Clip,
        vertex: VertexData,
        fragment: FragmentData,
        clear_color: [4]f32 = .{ 0, 0, 0, 1 },
    };

    pub var time: f32 = undefined;
    pub var clip: Clip = undefined;
    pub var cam: camera.State = undefined;

    pub fn update(frame_time: f32) State {
        time = frame_time;

        const clip_idx = util.scanTimeline(ClipSegment, timeline.clip_track, time);
        const clip_seg = timeline.clip_track[clip_idx];
        clip = clips[clip_idx];
        const clip_time = time - clip_seg.t;
        // TODO: next_time = time - timeline.clip_track[idx + 1].t ...

        const cam_idx = util.scanTimeline(CameraSegment, timeline.camera_track, time);
        const cam_seg = timeline.camera_track[cam_idx];
        const camFn = cam_fns[cam_idx];
        cam = camFn(time - cam_seg.t, cam_entries[cam_idx]);

        return .{
            .vertex = .{
                .view_projection = math.Mat4.perspective(
                    math.radians(cam.fov),
                    render.aspect,
                    1,
                    4096,
                ).mmul(math.Mat4.lookAt(
                    cam.pos,
                    cam.target,
                    math.vec3.YUP,
                )),
                .camera_position = .{
                    cam.pos[0],
                    cam.pos[1],
                    cam.pos[2],
                    1,
                },
                .time = clip_time,
            },
            .fragment = .{
                .sun_direction_intensity = .{ 0, -1, 0, 1 },
                .sun_color_ambient = .{ 1, 1, 1, 0.25 },
                .time = clip_time,
            },
            .clip = clip,
            .clear_color = .{ 0.5, 0.5, 0.5, 1 },
        };
    }
};

// ---- TEXTURES (2nd) ----

const logo_font_size = 128.0;
const noise_size: usize = 64;

var logo_font_glyphs: [128]font.GlyphInfo = undefined;

pub const TextureInfo = struct {
    tex_type: types.TextureType = .@"2d",
    format: types.TextureFormat,
    width: u32,
    height: u32,
    depth: u32 = 1,
    mip_levels: u32 = 1,
};

pub const texture = struct {
    pub const logo_font = struct {
        const name = "Unitblock.ttf";
        const dim = 1024;

        pub fn create() !TextureInfo {
            return .{
                .format = .r8_unorm,
                .width = dim,
                .height = dim,
            };
        }

        pub fn init(dst: []u8) !void {
            const ttf = try util.loadFile(gpa, name);
            defer gpa.free(ttf);

            try font.bakeSDFAtlas(
                ttf.ptr,
                logo_font_size,
                16,
                8,
                dim,
                dim,
                &logo_font_glyphs,
                dst.ptr,
            );
        }
    };

    pub const noise = struct {
        pub fn create() !TextureInfo {
            return .{
                .format = .r8_unorm,
                .width = noise_size,
                .height = noise_size,
            };
        }

        pub fn updateData(dst: []u8) !void {
            for (0..noise_size) |y| {
                for (0..noise_size) |x| {
                    const scale = 0.5;
                    const hash = std.hash.int(@as(u32, @bitCast(frame.time)));
                    const noise_val = noise_zig.simplex2(
                        (@as(f32, @floatFromInt(x)) * scale) + @as(f32, @floatFromInt(hash & 0x7fff)),
                        (@as(f32, @floatFromInt(y)) * scale),
                    );
                    dst[y * noise_size + x] =
                        @intFromFloat((noise_val * 0.5 + 0.5) * 256);
                }
            }
        }
    };
};

pub const Texture = std.meta.DeclEnum(texture);

// ---- BUFFERS (3rd) ----

pub const layout = struct {
    pub const VertexPosColor = extern struct {
        position: [3]f32,
        color: [3]f32,

        pub const locations = .{ 0, 2 };
    };

    pub const InstanceText = util.InstanceText;

    pub const InstanceTRS = extern struct {
        pos_scale: [4]f32,
        rot_quat: [4]f32,

        pub const locations = .{ 6, 7 };
    };

    // Assert that all layouts are extern structs
    comptime {
        for (@typeInfo(@This()).@"struct".decls) |decl| {
            if (@typeInfo(@field(@This(), decl.name)).@"struct".layout != .@"extern") {
                @compileError(std.fmt.comptimePrint("Layout {s} is not extern", .{decl.name}));
            }
        }
    }
};

pub const BufferInfo = struct {
    num_elements: u32,
    first_element: u32 = 0,
};

pub const buffer = struct {
    pub const octahedron = struct {
        const coords = .{
            // position1          position2            position3
            0.0, -1.0, 0.0, 0.66, 0.0, 0.66, -0.66, 0.0, 0.66, // lower front
            0.0, -1.0, 0.0, 0.66, 0.0, -0.66, 0.66, 0.0, 0.66, // lower right
            0.0, -1.0, 0.0, -0.66, 0.0, -0.66, 0.66, 0.0, -0.66, // lower back
            0.0, -1.0, 0.0, -0.66, 0.0, 0.66, -0.66, 0.0, -0.66, // lower left
            0.0, 1.0, 0.0, -0.66, 0.0, 0.66, 0.66, 0.0, 0.66, // upper front
            0.0, 1.0, 0.0, 0.66, 0.0, 0.66, 0.66, 0.0, -0.66, // upper right
            0.0, 1.0, 0.0, 0.66, 0.0, -0.66, -0.66, 0.0, -0.66, // upper back
            0.0, 1.0, 0.0, -0.66, 0.0, -0.66, -0.66, 0.0, 0.66, // upper left
        };
        const colors = .{
            0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3,
            0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1,
            0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3,
            0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1,
            0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5,
            0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7,
            0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5,
            0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7, 0.7,
        };
        const num_vertices = coords.len / 3;

        pub const Layout = layout.VertexPosColor;

        pub fn create() !u32 {
            return num_vertices;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            util.interleave(Layout, dst, .{ &coords, &colors });
            return .{ .num_elements = num_vertices };
        }
    };

    pub const logo_text = struct {
        const str = "Mehu\nMehu\nMehu";

        pub const Layout = layout.InstanceText;

        pub fn create() !u32 {
            return str.len;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            const num = util.genText(
                dst,
                str,
                logo_font_size,
                &logo_font_glyphs,
            );
            return .{ .num_elements = num };
        }
    };

    pub const oct_instances = struct {
        pub const Layout = layout.InstanceTRS;

        pub fn create() !u32 {
            return 512;
        }

        pub fn updateData(dst: []Layout) !void {
            for (dst) |*instance| {
                instance.* = .{
                    .pos_scale = .{ 0, 0, 0, 1 },
                    .rot_quat = math.quat.IDENTITY,
                };
            }
        }
    };
};

pub const Buffer = std.meta.DeclEnum(buffer);

// TODO: STORAGE TEXTURES (4th)

// ---- STORAGE BUFFERS (4th) ----

pub const storage_buffer = struct {
    pub const point_lights = struct {
        pub const Header = extern struct {
            count: u32,
            _pad: [3]u32 = @splat(0),
        };

        pub const Element = extern struct {
            position_radius: [4]f32,
            color_brightness: [4]f32,
        };

        const max_lights = config.max_lights;

        pub fn create() !u32 {
            return max_lights;
        }

        pub fn init(dst: []u8) !void {
            const header = .{
                .count = 1,
            };

            const lights = .{
                .{ .position = .{ 0, 2, 0, 0.5 }, .color = .{ 1, 0, 0, 5 } },
            };

            util.writeSSBO(Header, Element, dst, header, lights);
        }
    };
};

pub const StorageBuffer = std.meta.DeclEnum(storage_buffer);
