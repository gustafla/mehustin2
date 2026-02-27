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
const udp = @import("udp.zig");
const noise_zig = @import("script/noise.zig");
const timeline = @import("script/timeline.zig");
pub const Clip = timeline.Clip;
const util = @import("script/util.zig");

// ---- GLOBAL ----

pub var gpa: Allocator = undefined;

pub fn init(init_gpa: Allocator) void {
    gpa = init_gpa;
    if (options.udp_client) {
        udp.init("valot.instanssi.org") catch std.log.err("Name resolution failed", .{});
    }
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
var str_buf: [128]u8 = undefined;

pub const string = struct {
    pub var fps: []const u8 = "";
    pub var time: []const u8 = "";
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
        clip_length: f32,
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
        var buf: []u8 = &str_buf;
        if (options.show_fps) {
            frames += 1;
            const ticks = c.SDL_GetTicksNS();
            if (fps_ticks + c.SDL_NS_PER_SECOND < ticks) {
                string.fps = std.fmt.bufPrint(buf, "FPS: {}", .{frames}) catch unreachable;
                fps_ticks = ticks;
                frames = 0;
            }
            buf = buf[string.fps.len..];
        }

        time = frame_time;

        state = timeline.resolve(time);

        if (builtin.mode == .Debug) {
            string.time = std.fmt.bufPrint(buf, "{t} {:.1}", .{ state.clip, time }) catch unreachable;
            buf = buf[string.time.len..];
        }

        const view = math.Mat4.lookAt(
            state.camera.pos,
            state.camera.target,
            math.radians(state.camera.roll),
        );

        // Update partyhall lights
        if (options.udp_client) {
            udp.updateLights(0, 0, 0) catch std.log.err("UDP send failed", .{});
        }

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
                .clip_length = state.clip_length,
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
const surf_grid = .{ .w = 179, .d = 179 };
const surf_num_verts_x = surf_grid.w + 1;
const surf_num_verts_z = surf_grid.d + 1;

fn rotate(flag: bool, v: Vec3) Vec3 {
    if (flag) {
        return .{ v[2], v[1], v[0] };
    }
    return v;
}

const beam_mesh = struct {
    fn size(subdiv: u32) u32 {
        return 3 * 2 * 2 * subdiv;
    }

    fn init(
        dst: []layout.VertexPosUV0,
        segment_length: f32,
    ) void {
        const subdiv = dst.len / size(1);

        for (0..2) |i| {
            const base = 3 * 2 * subdiv * i;
            const r = i == 1;
            var y: f32 = segment_length;

            for (0..subdiv) |s| {
                const segment = s * 3 * 2;
                const v0 = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(subdiv));
                const v1 = v0 + 1.0 / @as(f32, @floatFromInt(subdiv));

                const y0 = y;
                const y1 = y - segment_length;

                const width = 0.25;
                dst[base + segment + 0] = .{ .position = rotate(r, .{ -width, y0, 0 }), .uv0 = .{ 0, v0 } };
                dst[base + segment + 1] = .{ .position = rotate(r, .{ -width, y1, 0 }), .uv0 = .{ 0, v1 } };
                dst[base + segment + 2] = .{ .position = rotate(r, .{ width, y0, 0 }), .uv0 = .{ 1, v0 } };
                dst[base + segment + 3] = .{ .position = rotate(r, .{ -width, y1, 0 }), .uv0 = .{ 0, v1 } };
                dst[base + segment + 4] = .{ .position = rotate(r, .{ width, y1, 0 }), .uv0 = .{ 1, v1 } };
                dst[base + segment + 5] = .{ .position = rotate(r, .{ width, y0, 0 }), .uv0 = .{ 1, v0 } };

                y = y1;
            }
        }
    }
};

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

    pub const InstanceTRSColor = extern struct {
        pos_scale: [4]f32,
        rot_quat: [4]f32,
        color: [4]f32,

        pub const locations = .{ 8, 9, 10 };
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
                    .void => @as(u32, @intFromFloat(
                        8192 * std.math.clamp(frame.state.clip_remaining_time / frame.state.clip_length - 0.5, 0, 1),
                    )),
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

    pub const tentacle = struct {
        pub const Layout = layout.VertexPosUV0;

        const subdiv = 12;
        pub const segment_length = 0.2;
        pub const len = subdiv * segment_length;

        pub fn create() !u32 {
            return 6 + beam_mesh.size(subdiv);
        }

        pub fn init(dst: []Layout) !BufferInfo {
            beam_mesh.init(dst[0 .. dst.len - 6], segment_length);

            dst[dst.len - 6] = .{ .position = .{ 0, 0.5, 0 }, .uv0 = .{ 0.5, 0 } };
            dst[dst.len - 5] = .{ .position = .{ -0.25, 0.2, 0 }, .uv0 = .{ 0, 0 } };
            dst[dst.len - 4] = .{ .position = .{ 0.25, 0.2, 0 }, .uv0 = .{ 1, 0 } };

            dst[dst.len - 3] = .{ .position = .{ 0, 0.5, 0 }, .uv0 = .{ 0.5, 0 } };
            dst[dst.len - 2] = .{ .position = .{ 0, 0.2, -0.25 }, .uv0 = .{ 0, 0 } };
            dst[dst.len - 1] = .{ .position = .{ 0, 0.2, 0.25 }, .uv0 = .{ 1, 0 } };

            return .{
                .num_elements = @intCast(dst.len),
            };
        }
    };

    pub const jellyfish_inst = struct {
        pub const Layout = layout.InstanceTRSColor;

        pub const n = 10;
        var origins: [n]Vec3 = undefined;

        pub fn create() !u32 {
            return n;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            _ = dst;

            var rng: std.Random.Xoshiro256 = .init(1236);
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
                const col = color(i);
                inst.* = .{
                    .pos_scale = .{
                        pos0[0],
                        pos0[1],
                        pos0[2],
                        scale(i),
                    },
                    .rot_quat = math.quat.rotationBetween(vec3.YUP, vec3.normalize(pos1 - pos0)),
                    .color = .{ col[0], col[1], col[2], 1 },
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
            return 5 + @sin(t * std.math.pi) * 5;
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

        pub fn color(i: usize) Vec3 {
            const t = @as(f32, @floatFromInt(i)) / n;
            return util.hslToRgb(.{ 30 + t * 100, 1, 10 });
        }

        pub fn updateInfo() BufferInfo {
            return .{
                .num_elements = switch (frame.state.clip) {
                    .surface, .descent => 0,
                    .garden => @intFromFloat(n * math.smoothstep(
                        std.math.clamp(
                            (frame.state.clip_time * 16) / frame.state.clip_length,
                            0,
                            1,
                        ),
                    )),
                    else => n,
                },
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

            const nrocks = 16;
            var rng: std.Random.Xoshiro256 = .init(11);
            const r = rng.random();
            for (0..nrocks) |i| {
                const rock = c.par_shapes_create_rock(@intCast(i), 3);
                const scale = std.math.pow(f32, std.Random.float(r, f32) * 4 + 2, 2);
                c.par_shapes_scale(
                    rock,
                    scale + std.Random.float(r, f32),
                    scale + std.Random.float(r, f32) * 2,
                    scale + std.Random.float(r, f32),
                );
                c.par_shapes_translate(
                    rock,
                    std.Random.float(r, f32) * 400 - 200,
                    y,
                    std.Random.float(r, f32) * 400 - 200,
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

    pub const dustcloud_inst = struct {
        pub const Layout = layout.VertexPos;

        pub const n = 4;

        pub fn create() !u32 {
            return n;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            var rng: std.Random.Xoshiro256 = .init(4123);
            const r = rng.random();
            for (dst) |*inst| {
                inst.* = .{
                    .position = .{
                        std.Random.float(r, f32) * 200 - 100,
                        -940 + std.Random.float(r, f32) * 50,
                        std.Random.float(r, f32) * 200 - 100,
                    },
                };
            }
            return .{
                .num_elements = @intCast(dst.len),
            };
        }
    };

    pub const floating_rock = struct {
        pub const Layout = layout.VertexPosNormal;

        pub var mesh: *c.par_shapes_mesh = undefined;

        pub fn create() !u32 {
            mesh = c.par_shapes_create_rock(4356, 2);
            return @intCast(mesh.npoints);
        }

        pub fn init(dst: []Layout) !BufferInfo {
            util.interleave(Layout, dst, .{
                mesh.points[0 .. dst.len * 3],
                mesh.normals[0 .. dst.len * 3],
            });
            return .{
                .num_elements = @intCast(dst.len),
            };
        }
    };

    pub const floating_rock_ind = struct {
        pub const Layout = c.PAR_SHAPES_T;
        pub const mesh = &floating_rock.mesh;

        pub fn create() !u32 {
            return @intCast(mesh.*.ntriangles * 3);
        }

        pub fn init(dst: []Layout) !BufferInfo {
            @memcpy(dst, mesh.*.triangles[0..dst.len]);
            return .{
                .num_elements = @intCast(dst.len),
            };
        }
    };

    pub const floating_rock_inst = struct {
        pub const Layout = layout.InstanceTRS;
        pub const n = 8;

        pub fn create() !u32 {
            return n;
        }

        pub fn updateData(dst: []Layout) !void {
            var rng: std.Random.Xoshiro256 = .init(41223);
            const r = rng.random();
            for (dst) |*inst| {
                inst.* = .{
                    .pos_scale = .{
                        r.float(f32) * 200 - 100,
                        -1000 + r.float(f32) * 200 + @sin(frame.time * 0.523 * r.float(f32)) * 2 * r.float(f32),
                        r.float(f32) * 200 - 100,
                        3.0 + r.float(f32) * 8.0,
                    },
                    .rot_quat = math.quat.fromAxisAngle(math.vec3.normalize(.{
                        r.float(f32) * 2 - 1.0,
                        r.float(f32) * 2 - 1.0,
                        r.float(f32) * 2 - 1.0,
                    }), frame.time * r.float(f32) * 0.2),
                };
            }
        }

        pub fn updateInfo() BufferInfo {
            return .{
                .num_elements = switch (frame.state.clip) {
                    .currents => n,
                    else => 0,
                },
            };
        }
    };

    pub const ribbon = struct {
        pub const Layout = layout.VertexPosUV0;

        pub const subdiv = 200;
        pub const segment_length = 0.2;

        pub fn create() !u32 {
            return beam_mesh.size(subdiv);
        }

        pub fn init(dst: []Layout) !BufferInfo {
            beam_mesh.init(dst, segment_length);

            return .{
                .num_elements = @intCast(dst.len),
            };
        }
    };

    pub const ribbon_inst = struct {
        pub const Layout = layout.InstanceTRS;

        const n = 3;

        pub fn create() !u32 {
            return n;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            dst[0] = .{
                .pos_scale = .{ 100, -995, -10, 5 },
                .rot_quat = math.quat.rotationBetween(vec3.YUP, vec3.XUP),
            };
            dst[1] = .{
                .pos_scale = .{ -10, -940, 100, 5 },
                .rot_quat = math.quat.rotationBetween(vec3.YUP, vec3.ZUP),
            };
            dst[2] = .{
                .pos_scale = .{ 10, -930, 100, 5 },
                .rot_quat = math.quat.rotationBetween(vec3.YUP, vec3.ZUP),
            };
            return .{
                .num_elements = @intCast(dst.len),
            };
        }
    };

    pub const bubble_inst = struct {
        pub const Layout = layout.VertexPos;

        const n = 10;
        const radius = 30;

        pub fn create() !u32 {
            return n;
        }

        pub fn init(dst: []Layout) !BufferInfo {
            var rng: std.Random.Xoshiro256 = .init(41223);
            const r = rng.random();

            for (dst) |*inst| {
                inst.* = .{
                    .position = .{
                        0 + r.float(f32) * radius,
                        -900 + r.float(f32) * radius,
                        0 + r.float(f32) * radius,
                    },
                };
            }
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
                .brightness = 6,
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
            const num_lights = buffer.jellyfish_inst.updateInfo().num_elements;
            const ambient_factor = @as(f32, @floatFromInt(num_lights)) /
                @as(f32, @floatFromInt(buffer.jellyfish_inst.n));
            const ambient_clip: f32 = switch (frame.state.clip) {
                .currents => 0.5,
                else => 0.3,
            };

            const header: Header = .{
                .ambient = @as(Vec3, @splat(ambient_factor * ambient_clip)),
                .count = num_lights,
            };

            var lights: [max_lights]Element = undefined;
            for (lights[0..header.count], 0..) |*light, i| {
                const color = buffer.jellyfish_inst.color(i);
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
