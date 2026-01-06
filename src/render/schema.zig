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

pub const Pass = struct {
    drawcalls: []const struct {
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
    },
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

pub fn PipelineKey(max_color_targets: usize) type {
    return struct {
        pipeline: Pipeline,
        vert_info: ShaderInfo,
        frag_info: ShaderInfo,
        color_targets_buf: [max_color_targets]TextureFormat,
        num_color_targets: u32,
        depth_target: ?TextureFormat,
    };
}

pub fn initPipelineSet(
    comptime config: Config,
    max_color_targets: usize,
) []const PipelineKey(max_color_targets) {
    // Find upper bound for pipelines defined in config
    const n = fold(config.passes, &.{ "drawcalls", "len" }, sum_field);

    // Initialize unique map keys with O(n^2) filtering
    var keys: [n]PipelineKey(max_color_targets) = undefined;
    var num_keys = 0;
    for (config.passes) |pass| {
        var color_targets = std.mem.zeroes([max_color_targets]TextureFormat);
        for (pass.color_targets, 0..) |format, i| {
            color_targets[i] = switch (format) {
                .index => |idx| config.color_textures[idx],
                .swapchain => .swapchain,
            };
        }
        outer: for (pass.drawcalls) |drawcall| {
            const candidate: PipelineKey(max_color_targets) = .{
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
            for (keys[0..num_keys]) |key| {
                if (std.meta.eql(key, candidate)) {
                    continue :outer;
                }
            }
            keys[num_keys] = candidate;
            num_keys += 1;
        }
    }

    return keys[0..num_keys];
}

pub fn initImageSet(comptime config: Config) []const []const u8 {
    // Find upper bound for images defined in render config
    const n = fold(config.passes, &.{ "drawcalls", "vertex_samplers" }, count_images) +
        fold(config.passes, &.{ "drawcalls", "fragment_samplers" }, count_images);

    // Initialize unique map keys with O(n^2) filtering
    var keys: [n][]const u8 = undefined;
    var num_keys = 0;
    for (config.passes) |pass| {
        for (pass.drawcalls) |drawcall| {
            for (.{
                drawcall.vertex_samplers,
                drawcall.fragment_samplers,
            }) |samplers| {
                outer: for (samplers) |sampler| {
                    switch (sampler) {
                        .image => |name| {
                            for (keys[0..num_keys]) |key| {
                                if (std.mem.eql(u8, name, key)) {
                                    continue :outer;
                                }
                            }
                            keys[num_keys] = name;
                            num_keys += 1;
                        },
                        else => {},
                    }
                }
            }
        }
    }

    return keys[0..num_keys];
}
