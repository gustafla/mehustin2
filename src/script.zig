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
    pub var jellyfish0: Vec3 = @splat(0);
    pub var jellyfish1: Vec3 = @splat(0);
    pub var jellyfish2: Vec3 = @splat(0);
    pub var jellyfish3: Vec3 = @splat(0);
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
        camera_right: [4]f32,
        camera_up: [4]f32,
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
    pub var state: timeline.State = undefined;

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

        state = timeline.resolve(time);

        const view = math.Mat4.lookAt(
            state.camera.pos,
            state.camera.target,
            math.radians(state.camera.roll),
        );

        return .{
            .vertex = .{
                .view_projection = math.Mat4.perspective(
                    math.radians(state.camera.fov),
                    render.aspect,
                    render.near,
                    render.far,
                ).mmul(view),
                .camera_position = .{
                    state.camera.pos[0],
                    state.camera.pos[1],
                    state.camera.pos[2],
                    1,
                },
                .camera_right = .{ view.col[0][0], view.col[1][0], view.col[2][0], 0 },
                .camera_up = .{ view.col[0][1], view.col[1][1], view.col[2][1], 0 },
                .global_time = time,
            },
            .fragment = .{
                .global_time = time,
                .clip_time = state.clip_time,
                .clip_remaining_time = state.clip_remaining_time,
            },
            .clip = state.clip,
        };
    }
};

// ---- TEXTURES (2nd) ----

const logo_font_size = 128.0;
const noise_size: usize = 64;
var sky_color: Vec4 = @splat(0.0);
const sun_dir = vec3.normalize(.{ 1, 0.5, 1 });

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

    pub const static_noise = struct {
        pub fn create() !TextureInfo {
            return .{
                .format = .r8_unorm,
                .width = noise_size,
                .height = noise_size,
            };
        }

        pub fn init(dst: []u8) !void {
            for (0..noise_size) |y| {
                for (0..noise_size) |x| {
                    const noise_val = noise_zig.simplex2(
                        (@as(f32, @floatFromInt(x))),
                        (@as(f32, @floatFromInt(y))),
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

            sky_color = util.ambientFromEnvmap(w, h, data, .{});

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

const surf_plane = .{ .w = 768, .d = 768 };
const surf_grid = .{ .w = 127, .d = 127 };
const surf_num_verts_x = surf_grid.w + 1;
const surf_num_verts_z = surf_grid.d + 1;

pub const layout = struct {
    pub const InstanceText = timeline.InstanceText;

    pub const VertexPos = extern struct {
        position: [3]f32,

        pub const locations = .{0};
    };

    pub const VertexPosUV0 = extern struct {
        position: [3]f32,
        uv0: [2]f32,

        pub const locations = .{ 0, 4 };
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

    pub const light_shaft_ind = struct {
        pub const num_tris = light_shaft.num_vertices;

        pub const Layout = u16;

        pub fn create() !u32 {
            return num_tris * 3;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            for (0..num_tris) |tri| {
                const i = tri * 3;
                dst[i] = 0;
                dst[i + 1] = @intCast(1 + (tri + 0) % num_tris);
                dst[i + 2] = @intCast(1 + (tri + 1) % num_tris);
            }
            return .{ .num_elements = num_tris * 3 };
        }
    };

    pub const light_shaft = struct {
        pub const num_vertices = 6;
        const radius = 0.1;

        pub const Layout = layout.VertexPos;

        pub fn create() !u32 {
            return 1 + num_vertices;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            dst[0] = .{
                .position = .{ 0, 1, 0 },
            };
            for (dst[1..], 0..) |*vertex, i| {
                const i_f32: f32 = @floatFromInt(i);
                const t: f32 = (i_f32 / num_vertices) * std.math.tau;
                vertex.* = .{
                    .position = .{ @cos(t) * radius, 0, @sin(t) * radius },
                };
            }

            return .{ .num_elements = 1 + num_vertices };
        }
    };

    pub const light_shaft_inst = struct {
        const num_inst = 1;

        pub const Layout = layout.InstanceTRS;

        pub fn create() !u32 {
            return num_inst;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            const rot = math.quat.rotationBetween(vec3.YUP, sun_dir);
            dst[0] = .{
                .pos_scale = .{ 0, -10, 0, 64 * 8 },
                .rot_quat = rot,
            };

            return .{ .num_elements = num_inst };
        }
    };

    pub const particle_inst = struct {
        pub const Layout = void;

        pub fn updateInfo() BufferInfo {
            return .{
                .first_element = 0,
                .num_elements = switch (frame.state.clip) {
                    .surface => 64,
                    .descent => 64 +
                        @as(u32, @intFromFloat((8192 - 64) *
                            math.smoothstep(
                                frame.state.clip_time / frame.state.clip_length,
                            ))),
                    else => 8192,
                },
            };
        }
    };

    pub const jellyfish = struct {
        pub const Layout = layout.VertexPos;

        pub const size_u = 24;
        pub const size_v = 6;

        pub fn create() !u32 {
            return 1 + size_u * (size_v - 1);
        }

        pub fn init(dst: []Layout) !BufferInfo {
            dst[0] = .{ .position = .{ 0, 0.5, 0 } };

            for (1..size_v) |vu| {
                const vf: f32 = @floatFromInt(vu);
                const v = vf / (size_v * 2);

                for (0..size_u) |uu| {
                    const uf: f32 = @floatFromInt(uu);
                    const u = uf / size_u;

                    const sinv = @sin(v * std.math.pi) * 0.5;
                    const x = @sin(u * std.math.pi * 2) * sinv;
                    const z = @cos(u * std.math.pi * 2) * sinv;
                    const y = @cos(v * std.math.pi) * 0.5;

                    dst[1 + (vu - 1) * size_u + uu] = .{ .position = .{ x, y, z } };
                }
            }

            return .{
                .num_elements = @intCast(dst.len),
            };
        }
    };

    pub const jellyfish_ind = struct {
        pub const Layout = u32;

        pub fn create() !u32 {
            return 3 * jellyfish.size_u + 6 * jellyfish.size_u * (jellyfish.size_v - 1);
        }

        pub fn init(dst: []Layout) !BufferInfo {
            for (0..jellyfish.size_u) |tri| {
                dst[tri * 3 + 0] = 0;
                dst[tri * 3 + 1] = @intCast(1 + tri);
                dst[tri * 3 + 2] = @intCast(1 + ((1 + tri) % jellyfish.size_u));
            }

            const base = 3 * jellyfish.size_u;

            for (1..jellyfish.size_v - 1) |vu| {
                const ring = 6 * jellyfish.size_u * (vu - 1);

                for (0..jellyfish.size_u) |uu| {
                    const quad = 6 * uu;

                    const v_0: u16 = @intCast(1 + (vu - 1) * jellyfish.size_u);
                    const v_1: u16 = @intCast(1 + vu * jellyfish.size_u);
                    const u_0: u16 = @intCast(uu);
                    const u_1: u16 = @intCast((uu + 1) % jellyfish.size_u);
                    dst[base + ring + quad + 0] = v_1 + u_0;
                    dst[base + ring + quad + 1] = v_0 + u_1;
                    dst[base + ring + quad + 2] = v_0 + u_0;
                    dst[base + ring + quad + 3] = v_1 + u_0;
                    dst[base + ring + quad + 4] = v_1 + u_1;
                    dst[base + ring + quad + 5] = v_0 + u_1;
                }
            }

            return .{
                .num_elements = @intCast(dst.len),
            };
        }
    };

    pub const jellyfish_inst = struct {
        pub const Layout = layout.InstanceTRS;

        pub const n = 32;
        var origins: [n]Vec3 = undefined;

        pub fn create() !u32 {
            return n;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            _ = dst;

            var rng: std.Random.Xoshiro256 = .init(123);
            const r = rng.random();
            for (&origins) |*pos| {
                const cube: Vec3 = .{
                    std.Random.float(r, f32),
                    std.Random.float(r, f32),
                    std.Random.float(r, f32),
                };
                pos.* = cube * @as(Vec3, @splat(2.0)) - @as(Vec3, @splat(1.0));
            }

            return .{ .num_elements = n };
        }

        pub fn updateData(dst: []Layout) !void {
            for (dst, 0..) |*inst, i| {
                const dt = 1.0 / 60.0;
                const pos0 = position(i, frame.time);
                const pos1 = position(i, frame.time + dt);
                inst.* = .{
                    .pos_scale = .{
                        pos0[0],
                        pos0[1],
                        pos0[2],
                        scale(i),
                    },
                    .rot_quat = math.quat.rotationBetween(vec3.YUP, vec3.normalize(pos1 - pos0)),
                };
            }

            var rng: std.Random.Xoshiro256 = .init(4);
            const r = rng.random();
            inline for (@typeInfo(anchor).@"struct".decls) |decl| {
                comptime if (!std.mem.startsWith(u8, decl.name, "jellyfish")) continue;
                const index = std.Random.intRangeLessThanBiased(r, usize, 0, n);
                @field(anchor, decl.name) = .{
                    dst[index].pos_scale[0],
                    dst[index].pos_scale[1],
                    dst[index].pos_scale[2],
                };
            }
        }

        pub fn scale(i: usize) f32 {
            const t = @as(f32, @floatFromInt(i)) / n;
            return 5 + @sin(t);
        }

        pub fn position(i: usize, time: f32) Vec3 {
            const t = time * 0.1;
            const o: f32 = @floatFromInt(i);
            var pos = origins[i];

            pos[0] += @sin(o * 3 + t * 0.453);
            pos[1] += @cos(o * 2 + t * 0.143) + @sin(pos[0] * 0.1);
            pos[2] += @sin(o * 1 + t * 0.253) + @sin(pos[1] * 0.23);

            const offset: Vec3 = .{ 40, -970, 40 };
            pos = pos * @as(Vec3, .{ 50, 20, 50 }) + offset;
            return .{
                pos[0],
                @max(pos[1], seafloor.y + scale(i)),
                pos[2],
            };
        }

        pub fn updateInfo() BufferInfo {
            const t = std.math.clamp((frame.state.clip_time * 16) / frame.state.clip_length, 0, 1);
            return .{
                .num_elements = @intFromFloat(n * math.smoothstep(t)),
            };
        }
    };

    pub const seafloor = struct {
        pub const Layout = layout.VertexPosNormal;
        pub const y = -1004;

        pub var mesh: *c.par_shapes_mesh = undefined;
        pub var nverts: u32 = undefined;
        pub var ninds: u32 = undefined;

        pub fn create() !u32 {
            mesh = c.par_shapes_create_plane(1, 1);
            c.par_shapes_rotate(mesh, -std.math.pi / 2.0, @ptrCast(&math.vec3.XUP));
            c.par_shapes_scale(mesh, 10000, 1, 10000);
            c.par_shapes_translate(mesh, -5000, y, 5000);

            const nrocks = 32;
            var rng: std.Random.Xoshiro256 = .init(3);
            const r = rng.random();
            for (0..nrocks) |i| {
                const rock = c.par_shapes_create_rock(@intCast(i), 3);
                const scale = std.math.pow(f32, std.Random.float(r, f32) * 4, 2);
                c.par_shapes_scale(
                    rock,
                    scale + std.Random.float(r, f32),
                    scale + std.Random.float(r, f32) * 10,
                    scale + std.Random.float(r, f32),
                );
                c.par_shapes_translate(
                    rock,
                    std.Random.float(r, f32) * 200 - 100,
                    y,
                    std.Random.float(r, f32) * 200 - 100,
                );
                c.par_shapes_merge_and_free(mesh, rock);
            }

            nverts = @intCast(mesh.npoints);
            ninds = @intCast(mesh.ntriangles * 3);
            return nverts;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            util.interleave(Layout, dst, .{
                mesh.points[0 .. nverts * 3],
                mesh.normals[0 .. nverts * 3],
            });
            return .{
                .num_elements = nverts,
            };
        }
    };

    pub const seafloor_ind = struct {
        pub const Layout = c.PAR_SHAPES_T;

        pub fn create() !u32 {
            return seafloor.ninds;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            @memcpy(dst, seafloor.mesh.triangles);
            c.par_shapes_free_mesh(seafloor.mesh);
            return .{
                .num_elements = @intCast(dst.len),
            };
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
            sun_dir: [3]f32,
            brightness: f32,
        };

        pub const Element = void;

        pub fn create() !u32 {
            return 0;
        }

        pub fn init(dst: []u8) !void {
            util.writeSSBO(Header, Element, dst, .{
                .sky_color = sky_color,
                .sun_dir = sun_dir,
                .brightness = 5,
            }, &.{});
        }
    };

    pub const point_lights = struct {
        pub const Header = extern struct {
            ambient: [3]f32,
            count: u32,
        };

        pub const Element = extern struct {
            position: [3]f32,
            _pad0: f32 = 0.0,
            color: [3]f32,
            _pad1: f32 = 0.0,
        };

        const max_lights = config.max_lights;

        pub fn create() !u32 {
            return max_lights;
        }

        pub fn updateData(dst: []u8) !void {
            const num_lights: u32 = switch (frame.state.clip) {
                .garden => @intCast(buffer.jellyfish_inst.updateInfo().num_elements),
                else => 0,
            };
            const base = 1.333;
            const color: Vec3 = .{ base, base * base, base * base * base };
            const ambient_factor = @as(f32, @floatFromInt(num_lights)) /
                @as(f32, @floatFromInt(buffer.jellyfish_inst.n));

            const header: Header = .{
                .ambient = color * @as(Vec3, @splat(ambient_factor * 0.2)),
                .count = num_lights,
            };

            var lights: [max_lights]Element = undefined;
            for (lights[0..header.count], 0..) |*light, i| {
                light.* = .{
                    .position = buffer.jellyfish_inst.position(i, frame.time),
                    .color = color * @as(Vec3, @splat(buffer.jellyfish_inst.scale(i))),
                };
            }

            util.writeSSBO(Header, Element, dst, header, &lights);
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
