const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const options = @import("options");

const config = @import("config.zon");

const math = @import("math.zig");
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const vec3 = math.vec3;
const render = @import("render.zig");
const c = @import("render/c.zig").c;
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

// ---- STRINGS ----

var frames: u32 = 0;
var fps_ticks: u64 = 0;
var fps_buf: [32]u8 = undefined;

pub const string = struct {
    pub var fps: []const u8 = "";
};

pub const String = std.meta.DeclEnum(string);

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
        if (options.show_fps) {
            frames += 1;
            const ticks = c.SDL_GetTicksNS();
            if (fps_ticks + c.SDL_NS_PER_SECOND < ticks) {
                string.fps = std.fmt.bufPrint(&fps_buf, "FPS: {}", .{frames}) catch unreachable;
                fps_ticks = ticks;
                frames = 0;
            }
        }

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
            .clear_color = .{
                sky_color[0],
                sky_color[1],
                sky_color[2],
                1,
            },
        };
    }
};

// ---- TEXTURES (2nd) ----

const logo_font_size = 128.0;
const noise_size: usize = 64;
var sky_color: Vec4 = @splat(0.0);

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

    pub const sky_envmap_hdr = struct {
        var data: [*]f32 = undefined;

        pub fn create() !TextureInfo {
            const path = try resource.dataFilePath(gpa, "lonely_road_afternoon_puresky_1k.hdr");
            defer gpa.free(path);
            var w: c_int, var h: c_int, var cif: c_int = .{ 0, 0, 0 };
            data = c.stbi_loadf(path, &w, &h, &cif, 4) orelse return error.StbiLoadFailed;

            // Compute average color, sky is the upper half
            sky_color = @splat(0);
            const wu: usize, const hu: usize = .{ @intCast(w), @intCast(h) };
            for (0..hu / 2) |y| {
                for (0..wu) |x| {
                    const i = (y * wu + x) * 4;
                    const color: Vec4 = .{ data[i], data[i + 1], data[i + 2], data[i + 3] };
                    sky_color += std.math.clamp(color, @as(Vec4, @splat(0.0)), @as(Vec4, @splat(10.0)));
                }
            }
            sky_color /= @as(Vec4, @splat(@floatFromInt(wu * hu / 2)));

            return .{
                .format = .r32g32b32a32_float,
                .width = @intCast(w),
                .height = @intCast(h),
            };
        }

        pub fn init(dst: []u8) !void {
            const ptr: [*]u8 = @ptrCast(data);
            @memcpy(dst, ptr);
            c.stbi_image_free(data);
        }
    };
};

pub const Texture = std.meta.DeclEnum(texture);

// ---- BUFFERS (3rd) ----

const surf_plane = .{ .w = 100, .d = 100 };
const surf_grid = .{ .w = 128, .d = 128 };
const surf_num_verts_x = surf_grid.w + 1;
const surf_num_verts_z = surf_grid.d + 1;

pub const layout = struct {
    pub const InstanceText = timeline.InstanceText;

    pub const VertexPos = extern struct {
        position: [3]f32,

        pub const locations = .{0};
    };

    pub const VertexPosNormal = extern struct {
        position: [3]f32,
        normal: [3]f32,

        pub const locations = .{ 0, 1 };
    };

    pub const InstanceTRS = extern struct {
        pos_scale: [4]f32,
        rot_quat: [4]f32,

        pub const locations = .{ 8, 9 };
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

    pub const water_surface_ind = struct {
        const per_row = (surf_grid.w + 1) * 2;
        const num_indices = (per_row * surf_grid.d) + (surf_grid.d - 1) * 2;

        pub const Layout = u32;

        pub fn create() !u32 {
            return num_indices;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            var i: usize = 0;
            for (0..surf_grid.d) |z| {
                const row_current = z * surf_num_verts_x;
                const row_next = (z + 1) * surf_num_verts_x;

                for (0..surf_num_verts_x) |x| {
                    const top = @as(u32, @intCast(row_current + x));
                    const bot = @as(u32, @intCast(row_next + x));

                    dst[i] = top;
                    i += 1;
                    dst[i] = bot;
                    i += 1;
                }

                // Add Degenerate Triangle at end of row (except for the last row)
                if (z < surf_grid.d - 1) {
                    dst[i] = dst[i - 1];
                    i += 1;
                    dst[i] = @as(u32, @intCast((z + 1) * surf_num_verts_x));
                    i += 1;
                }
            }

            std.debug.assert(i == num_indices);

            return .{ .num_elements = num_indices };
        }
    };

    pub const water_surface = struct {
        const num_vertices = surf_num_verts_x * surf_num_verts_z;

        pub const Layout = layout.VertexPos;

        pub fn create() !u32 {
            return num_vertices;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            var i: usize = 0;
            for (0..surf_num_verts_z) |z| {
                for (0..surf_num_verts_x) |x| {
                    const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(surf_grid.w));
                    const v = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(surf_grid.d));
                    const px = (u - 0.5) * surf_plane.w;
                    const pz = (v - 0.5) * surf_plane.d;
                    dst[i] = .{ .position = .{ px, 0, pz } };
                    i += 1;
                }
            }

            return .{ .num_elements = num_vertices };
        }
    };
};

pub const Buffer = std.meta.DeclEnum(buffer);

// TODO: STORAGE TEXTURES (4th)

// ---- STORAGE BUFFERS (4th) ----

pub const storage_buffer = struct {
    pub const water_parameters = struct {
        pub const Header = extern struct {
            sky_color: [4]f32,
            deep_color: [4]f32,
        };

        pub const Element = void;

        pub fn create() !u32 {
            return 0;
        }

        pub fn init(dst: []u8) !void {
            util.writeSSBO(Header, Element, dst, .{
                .sky_color = sky_color,
                .deep_color = .{ 0.01, 0.05, 0.06, 1.0 },
            }, &.{});
        }
    };

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
            if (ssbo.Element != void and @typeInfo(ssbo.Element).@"struct".layout != .@"extern") {
                @compileError(std.fmt.comptimePrint("{s}.Element is not extern", .{decl.name}));
            }
            if (@sizeOf(ssbo.Header) % 16 != 0) {
                @compileError(std.fmt.comptimePrint("{s}.Header size is not a multiple of 16", .{decl.name}));
            }
        }
    }
};

pub const StorageBuffer = std.meta.DeclEnum(storage_buffer);
