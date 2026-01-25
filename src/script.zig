const std = @import("std");
const Allocator = std.mem.Allocator;

const timeline: Timeline = @import("timeline.zon");

const math = @import("math.zig");
const render = @import("render.zig");
const types = @import("render/types.zig");
const resource = @import("resource.zig");
const camera = @import("script/camera.zig");
const CameraState = camera.CameraState;
const font = @import("script/font.zig");
const noise = @import("script/noise.zig");
const schema = @import("script/schema.zig");
const Timeline = schema.Timeline;
const util = @import("script/util.zig");

pub const Clip = schema.ClipEnum(timeline);

var gpa: Allocator = undefined;

pub fn init(init_gpa: Allocator) void {
    gpa = init_gpa;
}

// ---- UNIFORMS (1st) ----

pub const VertexFrameData = extern struct {
    view_projection: math.Mat4,
    camera_position: [4]f32,
    time: f32,
};

pub const FragmentFrameData = extern struct {
    sun_direction_intensity: [4]f32,
    sun_color_ambient: [4]f32,
    time: f32,
};

pub const FrameData = struct {
    vertex: VertexFrameData,
    fragment: FragmentFrameData,
    clip: Clip,
};

pub fn updateFrame(time: f32) FrameData {
    // TODO: scan clip track, adjust uniform time
    const clip = @field(Clip, timeline.clip_track[0].id);
    // TODO: scan camera track, evaluate camera
    const cam_init: CameraState = .{
        .pos = .{ 0, 0, 4 },
        .target = .{ 0, 0, 0 },
    };
    const cam_state = @field(camera, "cam" ++ timeline.camera_track[0].id)(time, cam_init);

    return .{
        .vertex = .{
            .view_projection = math.Mat4.perspective(
                math.radians(cam_state.fov),
                render.aspect,
                1,
                4096,
            ).mmul(math.Mat4.lookAt(
                cam_state.pos,
                cam_state.target,
                math.vec3.YUP,
            )),
            .camera_position = .{
                cam_state.pos[0],
                cam_state.pos[1],
                cam_state.pos[2],
                1,
            },
            .time = time,
        },
        .fragment = .{
            .sun_direction_intensity = .{ 0, -1, 0, 1 },
            .sun_color_ambient = .{ 1, 1, 1, 0.25 },
            .time = time,
        },
        .clip = clip,
    };
}

// ---- TEXTURES (2nd) ----

pub const TextureInit = struct {
    tex_type: types.TextureType = .@"2d",
    format: types.TextureFormat,
    width: u32,
    height: u32,
    depth: u32 = 1,
    mip_levels: u32 = 1,
    data: ?*anyopaque = null,
    initFn: ?*const fn (@This(), []u8) void = null,
};

const logo_font_size = 128.0;
var logo_font_glyphs: [128]font.GlyphInfo = undefined;

pub fn initTextureLogoFont() !TextureInit {
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
            fn init(self: TextureInit, dst: []u8) void {
                const data: [*]u8 = @ptrCast(self.data.?);
                @memcpy(dst, data);
                gpa.free(data[0..dst.len]);
            }
        }.init,
    };
}

const noise_size: usize = 64;

pub fn initTextureNoise() !TextureInit {
    return .{
        .format = .r8_unorm,
        .width = noise_size,
        .height = noise_size,
    };
}

pub fn updateTextureNoise(time: f32, dst: []u8) void {
    for (0..noise_size) |y| {
        for (0..noise_size) |x| {
            const scale = 0.5;
            const hash = std.hash.int(@as(u32, @bitCast(time)));
            const noise_val = noise.simplex2(
                (@as(f32, @floatFromInt(x)) * scale) + @as(f32, @floatFromInt(hash & 0x7fff)),
                (@as(f32, @floatFromInt(y)) * scale),
            );
            dst[y * noise_size + x] =
                @intFromFloat((noise_val * 0.5 + 0.5) * 256);
        }
    }
}

// ---- BUFFERS (3rd) ----

pub const BufferInit = struct {
    elements: u32,
    layout: render.BufferLayoutEnum,
    data: ?*anyopaque = null,
    initFn: ?*const fn (@This(), usize, []u8) u32 = null,
};

pub fn initBufferOctahedron() !BufferInit {
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
        .elements = coords.len / 3,
        .layout = .vertex_pos_color,
        .initFn = &struct {
            fn init(self: BufferInit, pitch: usize, dst: []u8) u32 {
                util.interleave(f32, &.{ 3, 3 }, &.{ &coords, &colors }, pitch, dst);
                return self.elements;
            }
        }.init,
    };
}

pub fn initBufferLogoText() !BufferInit {
    const str = "Mehu\nMehu\nMehu";

    return .{
        .elements = str.len,
        .layout = .instance_text,
        .initFn = &struct {
            fn init(self: BufferInit, pitch: usize, dst: []u8) u32 {
                _ = self;
                return util.genText(
                    str,
                    logo_font_size,
                    &logo_font_glyphs,
                    pitch,
                    dst,
                );
            }
        }.init,
    };
}
