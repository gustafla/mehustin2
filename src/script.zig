const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("config.zon");

const math = @import("math.zig");
const Vec3 = math.Vec3;
const vec3 = math.vec3;
const render = @import("render.zig");
const types = @import("render/types.zig");
const resource = @import("resource.zig");
const camera = @import("script/camera.zig");
const noise_zig = @import("script/noise.zig");
const timeline = @import("script/timeline.zig");
pub const Clip = timeline.Clip;
const util = @import("script/util.zig");

// ---- GLOBAL ----

pub var gpa: Allocator = undefined;

pub fn init(init_gpa: Allocator) void {
    gpa = init_gpa;
}

// ---- ANCHORS ----

pub const anchor = struct {
    pub var origin: Vec3 = @splat(0);
};

pub const Anchor = std.meta.DeclEnum(anchor);

// ---- FRAME DATA (1st) ----

pub const frame = struct {
    pub const VertexUniforms = extern struct {
        view_projection: math.Mat4,
        camera_position: [4]f32,
        global_time: f32,
    };

    pub const FragmentUniforms = extern struct {
        global_time: f32,
        clip_time: f32,
        clip_remaining_time: f32,
    };

    pub const State = struct {
        clip: Clip,
        vertex: VertexUniforms,
        fragment: FragmentUniforms,
        clear_color: [4]f32 = .{ 0, 0, 0, 1 },
    };

    pub var time: f32 = undefined;
    pub var clip: Clip = undefined;
    pub var cam: camera.State = undefined;

    pub fn update(frame_time: f32) State {
        time = frame_time;

        const state = timeline.resolve(time);
        clip = state.clip;
        cam = state.camera;

        return .{
            .vertex = .{
                .view_projection = math.Mat4.perspective(
                    math.radians(cam.fov),
                    render.aspect,
                    render.near,
                    render.far,
                ).mmul(math.Mat4.lookAt(
                    cam.pos,
                    cam.target,
                    math.radians(cam.roll),
                )),
                .camera_position = .{
                    cam.pos[0],
                    cam.pos[1],
                    cam.pos[2],
                    1,
                },
                .global_time = time,
            },
            .fragment = .{
                .global_time = time,
                .clip_time = state.clip_time,
                .clip_remaining_time = state.clip_remaining_time,
            },
            .clip = clip,
            .clear_color = .{ 0.5, 0.5, 0.5, 1 },
        };
    }
};

// ---- TEXTURES (2nd) ----

const logo_font_size = 128.0;
const noise_size: usize = 64;

pub const TextureInfo = struct {
    tex_type: types.TextureType = .@"2d",
    format: types.TextureFormat,
    width: u32,
    height: u32,
    depth: u32 = 1,
    mip_levels: u32 = 1,
};

pub const texture = struct {
    pub const font_atlas = timeline.font_atlas;

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
    pub const InstanceText = timeline.InstanceText;

    pub const VertexPosColor = extern struct {
        position: [3]f32,
        color: [3]f32,

        pub const locations = .{ 0, 2 };
    };

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
    pub const text_instances = timeline.text_instances;

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

    pub const oct_instances = struct {
        pub const Layout = layout.InstanceTRS;

        pub fn create() !u32 {
            return 512;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            for (dst) |*instance| {
                instance.* = .{
                    .pos_scale = .{ 0, 0, 0, 1 },
                    .rot_quat = math.quat.IDENTITY,
                };
            }
            return .{ .num_elements = @intCast(dst.len) };
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
            position: [3]f32,
            radius: f32,
            color: [3]f32,
            brightness: f32,
        };

        const max_lights = config.max_lights;

        pub fn create() !u32 {
            return max_lights;
        }

        pub fn updateData(dst: []u8) !void {
            const header: Header = .{
                .count = 1,
            };

            const lights: []const Element = &.{
                .{ .position = .{ 0, 2, 0 }, .radius = 0.5, .color = .{ 1, 0, 0 }, .brightness = 5 },
            };

            util.writeSSBO(Header, Element, dst, header, lights);
        }
    };

    // Assert that all headers and elements are extern structs
    // and that the header doesn't break alignment
    comptime {
        for (@typeInfo(@This()).@"struct".decls) |decl| {
            const ssbo = @field(@This(), decl.name);
            if (@typeInfo(ssbo.Header).@"struct".layout != .@"extern") {
                @compileError(std.fmt.comptimePrint("{s}.Header is not extern", .{decl.name}));
            }
            if (@typeInfo(ssbo.Element).@"struct".layout != .@"extern") {
                @compileError(std.fmt.comptimePrint("{s}.Element is not extern", .{decl.name}));
            }
            if (@sizeOf(ssbo.Header) % 16 != 0) {
                @compileError(std.fmt.comptimePrint("{s}.Header size is not a multiple of 16", .{decl.name}));
            }
        }
    }
};

pub const StorageBuffer = std.meta.DeclEnum(storage_buffer);
