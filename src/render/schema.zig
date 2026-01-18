const std = @import("std");

const types = @import("types.zig");
const TextureFormat = types.TextureFormat;
const VertexData = types.VertexData;
const VertexAttributes = types.VertexAttributes;
const VertexFormat = types.VertexFormat;
const PrimitiveType = types.PrimitiveType;
const CompareOp = types.CompareOp;
const BlendState = types.BlendState;
const Filter = types.Filter;
const SamplerMipmapMode = types.SamplerMipmapMode;
const SamplerAddressMode = types.SamplerAddressMode;

pub const num_vertex_uniform_buffers = 1;
pub const num_fragment_uniform_buffers = 2;

pub const VertexSource = union(enum) {
    static: VertexData,
};

pub const InstanceSource = union(enum) {
    text: []const u8,
};

pub const Font = struct {
    ttf: []const u8,
    size: f32,
    padding: u32 = 8,
    dist_scale: f32 = 8,
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
    font: Font,
    image: []const u8,
    simplex2,
};

pub const Sampler = struct {
    min_filter: Filter = .nearest,
    mag_filter: Filter = .nearest,
    mipmap_mode: SamplerMipmapMode = .nearest,
    address_mode_u: SamplerAddressMode = .mirrored_repeat,
    address_mode_v: SamplerAddressMode = .mirrored_repeat,
    address_mode_w: SamplerAddressMode = .clamp_to_edge,
    mip_lod_bias: f32 = 0,
    max_anisotropy: f32 = 0,
    compare_op: CompareOp = .less_or_equal,
    min_lod: f32 = 0,
    max_lod: f32 = 1024,
    enable_anisotropy: bool = false,
    enable_compare: bool = false,
};

pub const TextureSamplerBinding = struct {
    texture: Texture,
    sampler: Sampler = .{},
};

pub const Drawcall = struct {
    pipelines: []const Pipeline,
    vertices: ?usize = null,
    instances: ?InstanceSource = null,
    vertex_samplers: []const TextureSamplerBinding = &.{},
    fragment_samplers: []const TextureSamplerBinding = &.{},
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

pub const TargetTexture = struct {
    format: TextureFormat,
    p: u32 = 1,
    q: u32 = 1,
};

pub const Config = struct {
    color_textures: []const TargetTexture = &.{},
    depth_textures: []const TargetTexture = &.{},
    vertices: []const VertexSource,
    passes: []const Pass,
    noise_size: u32 = 256,
    noise_scale: f32 = 0.5,
};

// Compute upper bounds by traversing structures
pub fn fold(
    comptime parent: anytype,
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
    if (is_iterable) {
        var acc = opt.init;
        for (parent) |elem| {
            const val = fold(elem, fields, opt);
            acc = opt.op(acc, val);
        }
        return acc;
    }
    @compileError(fields[0] ++ " not found in " ++ @typeName(Parent));
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

pub const count_nonnull = struct {
    const init: usize = 0;
    const op = sum_field.op;
    pub fn map(field: anytype) usize {
        return @intFromBool(field != null);
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
            pipe_idx: usize = 0,

            pub fn next(self: *@This()) ?PipelineKey(config) {
                while (self.pass_idx < config.passes.len) {
                    const pass = config.passes[self.pass_idx];

                    if (self.draw_idx >= pass.drawcalls.len) {
                        self.pass_idx += 1;
                        self.draw_idx = 0;
                        continue;
                    }

                    const drawcall = pass.drawcalls[self.draw_idx];

                    // Iterate over the pipelines within the drawcall
                    if (self.pipe_idx < drawcall.pipelines.len) {
                        const pipeline = drawcall.pipelines[self.pipe_idx];

                        // Pass the specific pipeline to init
                        // The drawcall data is shared
                        const key = init(pass, drawcall, pipeline);

                        self.pipe_idx += 1;
                        return key;
                    }

                    // Finished all pipelines for this drawcall, move to next
                    self.pipe_idx = 0;
                    self.draw_idx += 1;
                }

                return null;
            }
        };

        pub fn init(
            comptime pass: Pass,
            comptime drawcall: Drawcall,
            comptime pipeline: Pipeline,
        ) @This() {
            var color_targets = std.mem.zeroes([max_color_targets]TextureFormat);
            for (pass.color_targets, 0..) |format, i| {
                color_targets[i] = switch (format) {
                    .index => |idx| config.color_textures[idx].format,
                    .swapchain => .swapchain,
                };
            }
            return .{
                .pipeline = pipeline,
                .vert_info = .{
                    .num_samplers = drawcall.vertex_samplers.len,
                    .num_storage_textures = 0,
                    .num_storage_buffers = 0,
                    .num_uniform_buffers = num_vertex_uniform_buffers,
                },
                .frag_info = .{
                    .num_samplers = drawcall.fragment_samplers.len,
                    .num_storage_textures = 0,
                    .num_storage_buffers = 0,
                    .num_uniform_buffers = num_fragment_uniform_buffers,
                },
                .color_targets_buf = color_targets,
                .num_color_targets = pass.color_targets.len,
                .depth_target = if (pass.depth_target) |i| config.depth_textures[i].format else null,
            };
        }
    };
}

pub fn ImageKey(comptime config: Config) type {
    return struct {
        name: []const u8,

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
                        switch (sampler.texture) {
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

pub fn FontKey(comptime config: Config) type {
    return struct {
        font: Font,

        pub const Iterator = struct {
            pass_idx: usize = 0,
            draw_idx: usize = 0,
            stage_idx: usize = 0, // 0 = vertex_samplers, 1 = fragment_samplers
            sampler_idx: usize = 0,

            pub fn next(self: *@This()) ?FontKey(config) {
                // Loop until we find a valid .font or exhaust the config
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
                        switch (sampler.texture) {
                            .font => |font| {
                                return .{ .font = font };
                            },
                            else => continue, // Skip non-fonts, keep looping
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

pub fn InstanceKey(comptime config: Config) type {
    return struct {
        instances: InstanceSource,
        font_key: ?FontKey(config) = null, // Only valid for .text

        pub const Iterator = struct {
            pass_idx: usize = 0,
            draw_idx: usize = 0,

            pub fn next(self: *@This()) ?InstanceKey(config) {
                while (self.pass_idx < config.passes.len) {
                    const pass = config.passes[self.pass_idx];

                    if (self.draw_idx >= pass.drawcalls.len) {
                        self.pass_idx += 1;
                        self.draw_idx = 0;
                        continue;
                    }

                    const draw = pass.drawcalls[self.draw_idx];

                    // Only yield a key if this drawcall has instances
                    if (draw.instances) |inst| {
                        const key = init(draw, inst);
                        // 1 instance buffer per drawcall
                        self.draw_idx += 1;
                        return key;
                    }

                    self.draw_idx += 1;
                }
                return null;
            }
        };

        fn findFontKey(drawcall: Drawcall) FontKey(config) {
            for (drawcall.fragment_samplers) |s| {
                if (s.texture == .font) return .{ .font = s.texture.font };
            }
            @compileError("Drawcall has text instances but no .font sampler!");
        }

        pub fn init(
            comptime drawcall: Drawcall,
            comptime instances: InstanceSource,
        ) @This() {
            return .{
                .instances = instances,
                .font_key = if (instances == .text) findFontKey(drawcall) else null,
            };
        }
    };
}

pub fn SamplerKey(comptime config: Config) type {
    return struct {
        sampler: Sampler,

        pub const Iterator = struct {
            pass_idx: usize = 0,
            draw_idx: usize = 0,
            stage_idx: usize = 0, // 0 = vertex_samplers, 1 = fragment_samplers
            sampler_idx: usize = 0,

            pub fn next(self: *@This()) ?SamplerKey(config) {
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
                        return .{ .sampler = sampler.sampler };
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
            if (std.meta.eql(existing, candidate)) continue :outer;
        }
        keys_buf[unique_count] = candidate;
        unique_count += 1;
    }

    const keys_array = keys_buf[0..unique_count].*;

    return struct {
        pub const keys = keys_array;

        pub fn getIndex(comptime key: T) usize {
            @setEvalBranchQuota(10000);
            for (keys, 0..) |k, i| {
                if (std.meta.eql(k, key)) return i;
            }
            @compileError("Key not found in ComptimeSet: " ++
                std.fmt.comptimePrint("{any}", .{key}));
        }
    };
}
