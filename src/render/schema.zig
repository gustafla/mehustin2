const std = @import("std");

const types = @import("types.zig");
const TextureFormat = types.TextureFormat;
const VertexData = types.VertexData;
const VertexAttributes = types.VertexAttributes;
const VertexFormat = types.VertexFormat;
const PrimitiveType = types.PrimitiveType;
const CompareOp = types.CompareOp;
const BlendState = types.BlendState;

pub const VertexSource = union(enum) {
    static: VertexData,
};

pub const Text = struct {
    str: []const u8,
    font: usize = 0,
};

pub const InstanceSource = union(enum) {
    text: Text,
};

pub const Font = struct {
    ttf: []const u8,
    size: f32,
    padding: u32 = 5,
    dist_scale: f32 = 32,
    atlas_width: u32 = 1024,
    atlas_height: u32 = 1024,
};

pub const Pipeline = struct {
    vert: []const u8 = "tri.vert",
    frag: []const u8,
    vertex_attributes: VertexAttributes = .{},
    instance_attributes: []const VertexFormat = &.{},
    primitive_type: PrimitiveType = .trianglestrip,
    depth_test: ?struct {
        compare_op: CompareOp = .less_or_equal,
        enable: bool = true,
        write: bool = true,
    } = null,
    blend_states: []const BlendState = &.{},
};

pub const UniformData = enum {
    matrices,
    shadertoy,
};

pub const DrawNum = union(enum) {
    infer,
    num: u32,
};

pub const ColorTarget = union(enum) {
    index: usize,
    swapchain,
};

pub const Texture = union(enum) {
    color: usize,
    depth: usize,
    font: usize,
    image: []const u8,
    simplex2,
};

pub const Drawcall =
    struct {
        pipeline: Pipeline,
        vertices: ?usize = null,
        instances: ?usize = null,
        vertex_samplers: []const Texture = &.{},
        fragment_samplers: []const Texture = &.{},
        vertex_uniforms: []const UniformData = &.{},
        fragment_uniforms: []const UniformData = &.{},
        num_vertices: DrawNum = .infer,
        num_instances: DrawNum = .infer,
        first_vertex: u32 = 0,
        first_instance: u32 = 0,
    };

pub const Pass = struct {
    drawcalls: []const Drawcall,
    color_targets: []const ColorTarget = &.{.swapchain},
    depth_target: ?usize = null,
};

pub const Config = struct {
    color_textures: []const TextureFormat = &.{},
    depth_textures: []const TextureFormat = &.{},
    vertices: []const VertexSource,
    instances: []const InstanceSource,
    fonts: []const Font,
    passes: []const Pass,
    noise_size: u32 = 256,
    noise_scale: f32 = 0.5,
};

// Compute upper bounds by traversing structures
pub fn fold(
    parent: anytype,
    comptime fields: []const []const u8,
    opt: anytype,
) @TypeOf(opt.init) {
    const Parent = @TypeOf(parent);
    const info = @typeInfo(Parent);
    const is_slice = info == .pointer and info.pointer.size == .slice;
    const is_string = is_slice and info.pointer.child == u8;
    const is_iterable = (is_slice or info == .array) and !is_string;

    // Base case, at leaf, yield it's value, optionally transformed via `map`.
    if (fields.len == 0 and !is_iterable) {
        if (@hasDecl(opt, "map")) {
            return opt.map(parent);
        }
        return parent;
    }

    // Then, if current field access works, always descent (e.g. `[]T.len`)
    if (fields.len > 0 and @hasField(Parent, fields[0])) {
        const child = @field(parent, fields[0]);
        return fold(child, fields[1..], opt);
    }

    // Finally, try iterating current parent
    var acc = opt.init;
    for (parent) |elem| {
        const val = fold(elem, fields, opt);
        acc = opt.op(acc, val);
    }

    return acc;
}

pub const max_field = struct {
    pub const init = 0;
    const T = @TypeOf(@This().init);
    pub fn op(acc: T, val: T) T {
        return @max(acc, val);
    }
};

pub const sum_field = struct {
    const init = 0;
    const T = @TypeOf(@This().init);
    pub fn op(acc: T, val: T) T {
        return acc + val;
    }
};

pub const count_images = struct {
    const init: usize = 0;
    const op = sum_field.op;
    fn map(texture: Texture) usize {
        return @intFromBool(texture == .image);
    }
};

const ShaderInfo = struct {
    num_samplers: u32,
    num_storage_textures: u32,
    num_storage_buffers: u32,
    num_uniform_buffers: u32,
};

pub fn PipelineKey(comptime config: Config) type {
    return struct {
        pipeline: Pipeline,
        vert_info: ShaderInfo,
        frag_info: ShaderInfo,
        color_targets_buf: [max_color_targets]TextureFormat,
        num_color_targets: u32,
        depth_target: ?TextureFormat,

        pub const max_color_targets = fold(config.passes, &.{
            "color_targets",
            "len",
        }, max_field);

        pub const Iterator = struct {
            pass_idx: usize = 0,
            draw_idx: usize = 0,

            pub fn next(self: *@This()) ?PipelineKey(config) {
                if (self.pass_idx >= config.passes.len) return null;

                const pass = config.passes[self.pass_idx];
                const drawcall = pass.drawcalls[self.draw_idx];

                const key = init(pass, drawcall);

                self.draw_idx += 1;
                if (self.draw_idx >= pass.drawcalls.len) {
                    self.draw_idx = 0;
                    self.pass_idx += 1;
                }

                return key;
            }
        };

        pub const eql = std.meta.eql;

        pub fn init(
            comptime pass: Pass,
            comptime drawcall: Drawcall,
        ) @This() {
            var color_targets = std.mem.zeroes([max_color_targets]TextureFormat);
            for (pass.color_targets, 0..) |format, i| {
                color_targets[i] = switch (format) {
                    .index => |idx| config.color_textures[idx],
                    .swapchain => .swapchain,
                };
            }
            return .{
                .pipeline = drawcall.pipeline,
                .vert_info = .{
                    .num_samplers = drawcall.vertex_samplers.len,
                    .num_storage_textures = 0,
                    .num_storage_buffers = 0,
                    .num_uniform_buffers = drawcall.vertex_uniforms.len,
                },
                .frag_info = .{
                    .num_samplers = drawcall.fragment_samplers.len,
                    .num_storage_textures = 0,
                    .num_storage_buffers = 0,
                    .num_uniform_buffers = drawcall.fragment_uniforms.len,
                },
                .color_targets_buf = color_targets,
                .num_color_targets = pass.color_targets.len,
                .depth_target = if (pass.depth_target) |i| config.depth_textures[i] else null,
            };
        }
    };
}

pub fn ImageKey(comptime config: Config) type {
    return struct {
        name: []const u8,

        pub fn eql(a: @This(), b: @This()) bool {
            return std.mem.eql(u8, a.name, b.name);
        }

        pub const Iterator = struct {
            pass_idx: usize = 0,
            draw_idx: usize = 0,
            stage_idx: usize = 0, // 0 = vertex_samplers, 1 = fragment_samplers
            sampler_idx: usize = 0,

            pub fn next(self: *@This()) ?ImageKey(config) {
                // Loop until we find a valid .image or exhaust the config
                while (self.pass_idx < config.passes.len) {
                    const pass = config.passes[self.pass_idx];

                    if (self.draw_idx >= pass.drawcalls.len) {
                        self.pass_idx += 1;
                        self.draw_idx = 0;
                        continue;
                    }

                    const draw = pass.drawcalls[self.draw_idx];

                    // Select the list based on current stage
                    const current_list = if (self.stage_idx == 0)
                        draw.vertex_samplers
                    else
                        draw.fragment_samplers;

                    // Iterate through the current sampler list
                    if (self.sampler_idx < current_list.len) {
                        const sampler = current_list[self.sampler_idx];
                        self.sampler_idx += 1; // Advance index immediately
                        switch (sampler) {
                            .image => |path| {
                                return .{ .name = path };
                            },
                            else => continue, // Skip non-images, keep looping
                        }
                    }

                    // End of current list reached: reset sampler, move to next stage
                    self.sampler_idx = 0;
                    self.stage_idx += 1;

                    // If we finished both stages (0 and 1), move to next drawcall
                    if (self.stage_idx > 1) {
                        self.stage_idx = 0;
                        self.draw_idx += 1;
                    }
                }

                return null;
            }
        };
    };
}

pub fn ComptimeSet(comptime T: type) type {
    var count_iter: T.Iterator = .{};
    var max_count = 0;
    while (count_iter.next()) |_| : (max_count += 1) {}

    var keys_buf: [max_count]T = undefined;
    var unique_count = 0;

    var collect_iter: T.Iterator = .{};
    outer: while (collect_iter.next()) |candidate| {
        for (keys_buf[0..unique_count]) |existing| {
            if (T.eql(existing, candidate)) continue :outer;
        }
        keys_buf[unique_count] = candidate;
        unique_count += 1;
    }

    const keys_array = keys_buf[0..unique_count].*;

    return struct {
        pub const keys = keys_array;

        pub fn getIndex(key: T) usize {
            for (keys, 0..) |k, i| {
                if (T.eql(k, key)) return i;
            }
            @compileError("Key not found in ComptimeSet: " ++
                std.fmt.comptimePrint("{any}", .{key}));
        }
    };
}
