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

pub const Clip = schema.ClipEnum(timeline);
const clips = schema.clipTable(timeline)[0..].*;
const cam_fns = schema.camFnTable(timeline)[0..].*;
const cam_entries = schema.camEntryTable(timeline)[0..].*;

// ---- GLOBAL ----

var gpa: Allocator = undefined;

pub fn init(init_gpa: Allocator) void {
    gpa = init_gpa;
}

// ---- BUFFER LAYOUTS ----

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
};

pub const Layout = std.meta.DeclEnum(layout);

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

pub const texture = struct {
    pub const Init = struct {
        tex_type: types.TextureType = .@"2d",
        format: types.TextureFormat,
        width: u32,
        height: u32,
        depth: u32 = 1,
        mip_levels: u32 = 1,
        data: ?*anyopaque = null,
        initFn: ?*const fn (@This(), []u8) void = null,
    };

    pub const logo_font_size = 128.0;
    const noise_size: usize = 64;

    pub var logo_font_glyphs: [128]font.GlyphInfo = undefined;

    pub const init = struct {
        pub fn logoFont() !Init {
            const name = "Unitblock.ttf";
            const dim = 1024;
            const ttf = try util.loadFile(gpa, name);
            defer gpa.free(ttf);
            const buf = try gpa.alloc(u8, dim * dim);
            try font.bakeSDFAtlas(
                ttf.ptr,
                logo_font_size,
                16,
                8,
                dim,
                dim,
                &logo_font_glyphs,
                buf.ptr,
            );

            return .{
                .format = .r8_unorm,
                .width = dim,
                .height = dim,
                .data = @ptrCast(buf.ptr),
                .initFn = &struct {
                    fn init(self: Init, dst: []u8) void {
                        const data: [*]u8 = @ptrCast(self.data.?);
                        @memcpy(dst, data);
                        gpa.free(data[0..dst.len]);
                    }
                }.init,
            };
        }

        pub fn noise() !Init {
            return .{
                .format = .r8_unorm,
                .width = noise_size,
                .height = noise_size,
            };
        }
    };

    pub const update = struct {
        pub fn noise(dst: []u8) void {
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

pub const Texture = std.meta.DeclEnum(texture.init);

// ---- BUFFERS (3rd) ----

pub const buffer = struct {
    pub const Init = struct {
        num_elements: u32,
        first_element: u32 = 0,
        layout: Layout,
        data: ?*anyopaque = null,
        initFn: ?*const fn (@This(), usize, []u8) u32 = null,
    };

    pub const init = struct {
        pub fn octahedron() !Init {
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

            return .{
                .num_elements = coords.len / 3,
                .layout = .VertexPosColor,
                .initFn = &struct {
                    fn init(self: Init, pitch: usize, dst: []u8) u32 {
                        util.interleave(f32, &.{ 3, 3 }, &.{ &coords, &colors }, pitch, dst);
                        return self.num_elements;
                    }
                }.init,
            };
        }

        pub fn logoText() !Init {
            const str = "Mehu\nMehu\nMehu";

            return .{
                .num_elements = str.len,
                .layout = .InstanceText,
                .initFn = &struct {
                    fn init(self: Init, pitch: usize, dst: []u8) u32 {
                        _ = self;
                        return util.genText(
                            str,
                            texture.logo_font_size,
                            &texture.logo_font_glyphs,
                            pitch,
                            dst,
                        );
                    }
                }.init,
            };
        }

        pub fn octInstances() !Init {
            return .{
                .num_elements = 512,
                .layout = .InstanceTRS,
            };
        }
    };

    pub const update = struct {
        pub fn octInstances(dst: []u8) void {
            const dst_cast: []layout.InstanceTRS = @ptrCast(@alignCast(dst));
            for (dst_cast, 0..) |*instance, i| {
                _ = i;
                instance.* = .{
                    .pos_scale = .{ 0, 0, 0, 1 },
                    .rot_quat = math.quat.IDENTITY,
                };
            }
        }
    };
};

pub const Buffer = std.meta.DeclEnum(buffer.init);
