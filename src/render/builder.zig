const std = @import("std");

const engine = @import("engine");
const Config = engine.schema.Render;
const types = engine.types;
const VertexAttributes = types.VertexAttributes;
const VertexFormat = types.VertexFormat;
const MultisampleState = types.MultisampleState;
const script = @import("script");

pub const num_vertex_uniform_buffers = 1;
pub const num_fragment_uniform_buffers = 2;

pub fn parseIndex(
    comptime name: []const u8,
) !?struct { ref: []const u8, idx: usize } {
    if (name[name.len - 1] != ']') return null;
    const bracket = std.mem.indexOfScalar(u8, name, '[') orelse
        return error.MissingOpeningBracket;
    const index_str = name[bracket + 1 .. name.len - 1];
    const index = try std.fmt.parseInt(usize, index_str, 0);
    return .{ .ref = name[0..bracket], .idx = index };
}

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
        pipeline: Config.Pipeline,
        vert_info: ShaderInfo,
        frag_info: ShaderInfo,
        vertex_layout: ?type,
        instance_layout: ?type,
        color_targets_buf: [max_color_targets]types.TextureFormat,
        num_color_targets: u32,
        depth_target: ?types.TextureFormat,
        sample_count: types.SampleCount,

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
            comptime pass: Config.Pass,
            comptime drawcall: Config.Drawcall,
            comptime pipeline: Config.Pipeline,
        ) @This() {
            var color_targets = std.mem.zeroes([max_color_targets]types.TextureFormat);
            for (pass.color_targets, 0..) |target, i| {
                color_targets[i] = switch (target.target) {
                    .index => |idx| config.color_targets[idx].format,
                    .swapchain => .swapchain,
                };
            }

            const sample_count: types.SampleCount = blk: {
                if (pass.color_targets.len == 0) break :blk .@"1";
                break :blk switch (pass.color_targets[0].target) {
                    .index => |idx| config.color_targets[idx].sample_count,
                    .swapchain => .@"1",
                };
            };

            return .{
                .pipeline = pipeline,
                .vert_info = .{
                    .num_samplers = drawcall.vertex_samplers.len,
                    .num_storage_textures = 0,
                    .num_storage_buffers = drawcall.vertex_storage_buffers.len,
                    .num_uniform_buffers = num_vertex_uniform_buffers,
                },
                .frag_info = .{
                    .num_samplers = drawcall.fragment_samplers.len,
                    .num_storage_textures = 0,
                    .num_storage_buffers = drawcall.fragment_storage_buffers.len,
                    .num_uniform_buffers = num_fragment_uniform_buffers,
                },
                .vertex_layout = if (drawcall.vertex_buffer) |name|
                    @field(script.buffer, name).Layout
                else
                    null,
                .instance_layout = if (drawcall.instance_buffer) |name|
                    @field(script.buffer, name).Layout
                else
                    null,
                .color_targets_buf = color_targets,
                .num_color_targets = pass.color_targets.len,
                .depth_target = if (pass.depth_target) |t| config.depth_targets[t.target].format else null,
                .sample_count = sample_count,
            };
        }
    };
}

pub fn ComptimeSet(comptime T: type) type {
    @setEvalBranchQuota(10000);
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

pub fn SamplerEnum(comptime config: Config) type {
    var fields: [config.samplers.len]std.builtin.Type.EnumField = undefined;
    for (config.samplers, 0..) |sampler, i| {
        fields[i] = .{ .name = sampler.name[0.. :0], .value = i };
    }
    return @Type(.{ .@"enum" = .{
        .tag_type = usize,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
}
