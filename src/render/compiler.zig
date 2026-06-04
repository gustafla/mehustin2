const std = @import("std");

const engine = @import("engine");
const schema = engine.schema;
const types = engine.types;
const ShaderStage = types.ShaderStage;
const VertexAttributes = types.VertexAttributes;
const VertexFormat = types.VertexFormat;
const MultisampleState = types.MultisampleState;
const TextureUsageFlags = types.TextureUsageFlags;
const BufferUsageFlags = types.BufferUsageFlags;
const script = @import("script");

pub const num_vertex_uniform_buffers = 1;
pub const num_fragment_uniform_buffers = 2;

pub fn parseIndex(
    comptime name: []const u8,
) !?struct { ref: []const u8, idx: usize } {
    if (name[name.len - 1] != ']') return null;
    const bracket = std.mem.findScalar(u8, name, '[') orelse
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
    const is_tagged_union = info == .@"union" and info.@"union".tag_type != null;

    // Base case, at leaf, yield it's value, optionally transformed via `map`.
    if (fields.len == 0 and !is_iterable) {
        if (@hasDecl(opt, "map")) {
            return opt.map(parent);
        }
        return parent;
    }

    // Then, if current field access works, always descent (e.g. `[]T.len`)
    if (fields.len > 0 and @hasField(Parent, fields[0])) {
        // Guard against inaccessible tagged unions, skip over such cases
        if (is_tagged_union) switch (parent) {
            inline else => |_, tag| if (!std.mem.eql(u8, @tagName(tag), fields[0])) {
                return opt.init;
            },
        };

        const child = @field(parent, fields[0]);
        return fold(child, fields[1..], opt);
    }

    // Finally, try iterating current parent
    if (is_iterable) {
        @setEvalBranchQuota(1000 * parent.len);
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

pub fn unrollPasses(comptime config: schema.Render) []const schema.Render.Pass {
    @setEvalBranchQuota(1024 * config.passes.len * config.templates.len);
    var num_passes = 0;
    for (config.passes) |pass| {
        switch (pass) {
            .unroll => |unroll| {
                const tmpl = schema.template.get(
                    schema.Render.Pass,
                    config.templates,
                    unroll.template,
                );
                num_passes += unroll.args.len * tmpl.passes.len;
            },
            else => num_passes += 1,
        }
    }

    @setEvalBranchQuota(10000 * num_passes);
    var unrolled_passes: [num_passes]schema.Render.Pass = undefined;
    var i = 0;

    for (config.passes) |pass| {
        switch (pass) {
            .unroll => |unroll| {
                const template = schema.template.get(
                    schema.Render.Pass,
                    config.templates,
                    unroll.template,
                );
                const params = template.params;
                for (unroll.args) |args| {
                    for (template.passes) |tpass| {
                        unrolled_passes[i] = schema.template.applySubstitution(
                            schema.template.SliceAllocatorComptime,
                            tpass,
                            params,
                            args,
                        ) catch unreachable;
                        i += 1;
                    }
                }
            },
            else => {
                unrolled_passes[i] = pass;
                i += 1;
            },
        }
    }

    const final_passes = unrolled_passes;
    return &final_passes;
}

pub fn GraphicsPipelineKey(comptime config: schema.Render) type {
    const passes = unrollPasses(config);

    return struct {
        pipeline: schema.Render.GraphicsPipeline,
        vert_spv_filename: []const u8,
        frag_spv_filename: []const u8,
        vert_info: ShaderInfo,
        frag_info: ShaderInfo,
        vertex_layout: ?type,
        instance_layout: ?type,
        color_targets_buf: [max_color_targets]types.TextureFormat,
        num_color_targets: u32,
        depth_target: ?types.TextureFormat,
        sample_count: types.SampleCount,

        const ShaderInfo = struct {
            num_samplers: u32,
            num_storage_textures: u32,
            num_storage_buffers: u32,
            num_uniform_buffers: u32,
        };

        pub const max_color_targets = fold(passes, &.{
            "render",
            "color_targets",
            "len",
        }, max_field);

        pub const num_keys = fold(passes, &.{
            "render",
            "drawcalls",
            "pipelines",
            "len",
        }, sum_field) + fold(passes, &.{
            "render",
            "drawcalls",
            "pipelines",
            "variants",
            "len",
        }, sum_field);

        pub const Iterator = struct {
            pass_idx: usize = 0,
            draw_idx: usize = 0,
            pipe_idx: usize = 0,
            variant_idx: ?usize = null,

            pub fn next(self: *@This()) ?GraphicsPipelineKey(config) {
                while (self.pass_idx < passes.len) {
                    const pass = switch (passes[self.pass_idx]) {
                        .render => |render_pass| render_pass,
                        .compute => {
                            self.pass_idx += 1;
                            continue;
                        },
                        .unroll => @compileError("Cannot use unroll in template"),
                    };

                    if (self.draw_idx >= pass.drawcalls.len) {
                        self.pass_idx += 1;
                        self.draw_idx = 0;
                        self.variant_idx = null;
                        continue;
                    }

                    const drawcall = pass.drawcalls[self.draw_idx];

                    // Iterate over the pipelines within the drawcall
                    if (self.pipe_idx < drawcall.pipelines.len) {
                        const pipeline = drawcall.pipelines[self.pipe_idx];
                        const key = init(
                            pass,
                            drawcall,
                            pipeline,
                            self.variant_idx,
                        );

                        self.variant_idx = if (self.variant_idx) |i| i + 1 else 0;

                        if (self.variant_idx.? >= pipeline.variants.len) {
                            self.pipe_idx += 1;
                            self.variant_idx = null;
                        }

                        return key;
                    }

                    // Finished all pipelines for this drawcall, move to next
                    self.pipe_idx = 0;
                    self.draw_idx += 1;
                    self.variant_idx = null;
                }

                return null;
            }
        };

        pub fn init(
            comptime pass: schema.Render.RenderPass,
            comptime drawcall: schema.Render.Drawcall,
            comptime pipeline: schema.Render.GraphicsPipeline,
            comptime variant: ?usize,
        ) @This() {
            var color_targets = std.mem.zeroes([max_color_targets]types.TextureFormat);
            for (pass.color_targets, 0..) |target, i| {
                color_targets[i] = if (std.mem.eql(u8, target.texture, "swapchain"))
                    .swapchain
                else blk: {
                    const reference = parseIndex(target.texture) catch |e|
                        @compileError(std.fmt.comptimePrint("{s}", .{@errorName(e)}));
                    break :blk if (reference) |result|
                        @field(config, result.ref)[result.idx].format
                    else
                        @field(script.texture, target.texture).format;
                };
            }

            const sample_count: types.SampleCount = blk: {
                if (pass.color_targets.len == 0) break :blk .@"1";

                const reference = parseIndex(pass.color_targets[0].texture) catch |e|
                    @compileError(std.fmt.comptimePrint("{s}", .{@errorName(e)}));
                break :blk if (reference) |result|
                    @field(config, result.ref)[result.idx].sample_count
                else
                    .@"1"; // .swapchain or script texture
            };

            const stages = pipeline.shader.resolve();
            const vert_params, const frag_params = if (variant) |i| .{
                pipeline.variants[i].vert_params,
                pipeline.variants[i].frag_params,
            } else .{ &.{}, &.{} };

            return .{
                .pipeline = pipeline,
                .vert_spv_filename = std.fmt.comptimePrint("{f}", .{
                    stages.vert.spvFilenameFmt(.vertex, null, vert_params),
                }),
                .frag_spv_filename = std.fmt.comptimePrint("{f}", .{
                    stages.frag.spvFilenameFmt(.fragment, null, frag_params),
                }),
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
                .depth_target = if (pass.depth_target) |t| blk: {
                    const reference = parseIndex(t.texture) catch |e|
                        @compileError(std.fmt.comptimePrint("{s}", .{@errorName(e)}));
                    break :blk if (reference) |result|
                        @field(config, result.ref)[result.idx].format
                    else
                        @field(script.texture, t.texture).format;
                } else null,
                .sample_count = sample_count,
            };
        }
    };
}

pub fn ComputePipelineKey(comptime config: schema.Render) type {
    const passes = unrollPasses(config);

    return struct {
        comp_spv_filename: []const u8,
        comp_info: CompInfo,

        const CompInfo = struct {
            num_samplers: u32,
            num_readonly_storage_textures: u32,
            num_readonly_storage_buffers: u32,
            num_readwrite_storage_textures: u32,
            num_readwrite_storage_buffers: u32,
            threadcount_x: u32,
            threadcount_y: u32,
            threadcount_z: u32,
        };

        pub const num_keys = fold(passes, &.{
            "compute",
            "dispatches",
            "len",
        }, sum_field) + fold(passes, &.{
            "compute",
            "dispatches",
            "variants",
            "len",
        }, sum_field);

        pub const Iterator = struct {
            pass_idx: usize = 0,
            dispatch_idx: usize = 0,
            variant_idx: ?usize = null,

            pub fn next(self: *@This()) ?ComputePipelineKey(config) {
                while (self.pass_idx < passes.len) {
                    const pass = switch (passes[self.pass_idx]) {
                        .compute => |compute_pass| compute_pass,
                        .render => {
                            self.pass_idx += 1;
                            continue;
                        },
                        .unroll => @compileError("Cannot use unroll in template"),
                    };

                    if (self.dispatch_idx >= pass.dispatches.len) {
                        self.pass_idx += 1;
                        self.dispatch_idx = 0;
                        self.variant_idx = null;
                        continue;
                    }

                    const dispatch = pass.dispatches[self.dispatch_idx];
                    const key = init(pass, dispatch, self.variant_idx);

                    self.variant_idx = if (self.variant_idx) |i| i + 1 else 0;

                    if (self.variant_idx.? >= dispatch.variants.len) {
                        self.dispatch_idx += 1;
                        self.variant_idx = null;
                    }

                    return key;
                }

                return null;
            }
        };

        pub fn init(
            comptime pass: schema.Render.ComputePass,
            comptime dispatch: schema.Render.ComputeDispatch,
            comptime variant: ?usize,
        ) @This() {
            const comp_params = if (variant) |i| dispatch.variants[i].comp_params else &.{};
            return .{
                .comp_spv_filename = std.fmt.comptimePrint("{f}", .{
                    dispatch.comp.spvFilenameFmt(.compute, dispatch.threads, comp_params),
                }),
                .comp_info = .{
                    .num_samplers = dispatch.samplers.len,
                    .num_readonly_storage_textures = dispatch.readonly_storage_textures.len,
                    .num_readonly_storage_buffers = dispatch.readonly_storage_buffers.len,
                    .num_readwrite_storage_textures = pass.readwrite_storage_textures.len,
                    .num_readwrite_storage_buffers = pass.readwrite_storage_buffers.len,
                    .threadcount_x = dispatch.threads.x,
                    .threadcount_y = dispatch.threads.y,
                    .threadcount_z = dispatch.threads.z,
                },
            };
        }
    };
}

fn serialize(key: anytype, writer: *std.Io.Writer) !void {
    // If value can be resolved (i.e. it's a convenience union), resolve it first
    const T = @TypeOf(key);
    const t_info = @typeInfo(T);
    if ((t_info == .@"struct" or
        t_info == .@"enum" or
        t_info == .@"union" or
        t_info == .@"opaque") and
        @hasDecl(T, "resolve"))
    {
        return serialize(key.resolve(), writer);
    }

    try writer.writeByte('{');
    switch (t_info) {
        .@"struct" => |info| for (info.fields) |field| {
            try serialize(@field(key, field.name), writer);
            try writer.writeByte(';');
        },
        .@"enum" => try writer.writeAll(@tagName(key)),
        .int, .float, .bool => try writer.print("{}", .{key}),
        .pointer => |info| if (info.size == .slice) {
            if (info.child == u8) {
                try writer.writeAll(key);
            } else for (key) |e| try serialize(e, writer);
        } else unreachable,
        .array => for (key) |e| try serialize(e, writer),
        .optional => if (key) |inner|
            try serialize(inner, writer)
        else
            try writer.writeAll("null"),
        .type => try writer.writeAll(@typeName(key)),
        else => @compileError("Type " ++ @typeName(T) ++ " not handled"),
    }
    try writer.writeByte('}');
}

pub fn ComptimeSet(comptime T: type) type {
    const max_len = 1024;

    @setEvalBranchQuota(T.num_keys * max_len * 4);

    // Deduplicate keys, serialize to strings
    var keys_buf: [T.num_keys]T = undefined;
    var string_buffers: [T.num_keys][max_len]u8 = undefined;
    var serialized_buf: [T.num_keys][]const u8 = undefined;
    var unique_count = 0;

    var collect_iter: T.Iterator = .{};
    outer: while (collect_iter.next()) |candidate| {
        var writer = std.Io.Writer.fixed(&string_buffers[unique_count]);
        serialize(candidate, &writer) catch @compileError("Key too long");
        const string = writer.buffered();
        for (serialized_buf[0..unique_count]) |existing| {
            if (std.mem.eql(u8, existing, string)) continue :outer;
        }
        keys_buf[unique_count] = candidate;
        serialized_buf[unique_count] = string;
        unique_count += 1;
    }

    const final_count = unique_count;
    const final_fields = serialized_buf[0..final_count].*;
    const final_keys = keys_buf[0..final_count].*;
    const TagInt = std.math.IntFittingRange(0, @max(final_count, 2) - 1);
    const Enum = @Enum(
        TagInt,
        .exhaustive,
        &final_fields,
        &std.simd.iota(TagInt, final_count),
    );

    return struct {
        pub const Tag = TagInt;
        pub const Set = Enum;

        pub const keys = final_keys;

        pub fn getIndex(comptime key: T) Tag {
            @setEvalBranchQuota(final_count * max_len * 2);
            var buffer: [max_len]u8 = undefined;
            var writer = std.Io.Writer.fixed(&buffer);
            serialize(key, &writer) catch unreachable;
            const string = writer.buffered();
            return @intFromEnum(@field(Set, string));
        }
    };
}

pub fn SamplerEnum(comptime config: schema.Render) type {
    var field_names: [config.samplers.len][]const u8 = undefined;
    var field_values: [config.samplers.len]usize = undefined;
    for (config.samplers, 0..) |sampler, i| {
        field_names[i] = sampler.name;
        field_values[i] = i;
    }
    return @Enum(usize, .exhaustive, &field_names, &field_values);
}

pub fn UsageFlags(comptime config: schema.Render) type {
    const passes = unrollPasses(config);

    return struct {
        color_targets: [config.color_targets.len]TextureUsageFlags,
        depth_targets: [config.depth_targets.len]TextureUsageFlags,
        textures: [@typeInfo(script.Texture).@"enum".fields.len]TextureUsageFlags,
        storage_buffers: [@typeInfo(script.StorageBuffer).@"enum".fields.len]BufferUsageFlags,

        pub const init: @This() = blk: {
            @setEvalBranchQuota(1000 * passes.len);
            var f = std.mem.zeroes(@This());

            for (passes) |pass| switch (pass) {
                .render => |rpass| {
                    if (rpass.depth_target) |depth_target| {
                        const result = parseIndex(depth_target.texture) catch unreachable;
                        if (result) |r| {
                            @field(f, r.ref)[r.idx].depth_stencil_target = true;
                        } else {
                            const idx = @intFromEnum(@field(script.Texture, depth_target.texture));
                            f.textures[idx].depth_stencil_target = true;
                        }
                        if (depth_target.resolve_texture) |resolve_texture| {
                            const res_result = parseIndex(resolve_texture) catch unreachable;
                            if (res_result) |r| {
                                @field(f, r.ref)[r.idx].depth_stencil_target = true;
                            } else {
                                const idx = @intFromEnum(@field(script.Texture, resolve_texture));
                                f.textures[idx].depth_stencil_target = true;
                            }
                        }
                    }
                    for (rpass.color_targets) |color_target| {
                        if (!std.mem.eql(u8, color_target.texture, "swapchain")) {
                            const result = parseIndex(color_target.texture) catch unreachable;
                            if (result) |r| {
                                @field(f, r.ref)[r.idx].color_target = true;
                            } else {
                                const idx = @intFromEnum(@field(script.Texture, color_target.texture));
                                f.textures[idx].color_target = true;
                            }
                        }
                        if (color_target.resolve_texture) |resolve_texture| {
                            if (!std.mem.eql(u8, resolve_texture, "swapchain")) {
                                const res_result = parseIndex(resolve_texture) catch unreachable;
                                if (res_result) |r| {
                                    @field(f, r.ref)[r.idx].color_target = true;
                                } else {
                                    const idx = @intFromEnum(@field(script.Texture, resolve_texture));
                                    f.textures[idx].color_target = true;
                                }
                            }
                        }
                    }
                    for (rpass.drawcalls) |draw| {
                        for (.{ "vertex", "fragment" }) |stage| {
                            for (@field(draw, stage ++ "_samplers")) |binding| {
                                const result = parseIndex(binding.texture) catch unreachable;
                                if (result) |r| {
                                    @field(f, r.ref)[r.idx].sampler = true;
                                } else {
                                    const idx = @intFromEnum(@field(script.Texture, binding.texture));
                                    f.textures[idx].sampler = true;
                                }
                            }
                            for (@field(draw, stage ++ "_storage_buffers")) |binding| {
                                const idx = @intFromEnum(@field(script.StorageBuffer, binding));
                                f.storage_buffers[idx].graphics_storage_read = true;
                            }
                        }
                    }
                },
                .compute => |cpass| {
                    for (cpass.readwrite_storage_textures) |rwst| {
                        const result = parseIndex(rwst.texture) catch unreachable;
                        if (result) |r| {
                            @field(f, r.ref)[r.idx].compute_storage_read = true;
                            @field(f, r.ref)[r.idx].compute_storage_write = true;
                        } else {
                            const idx = @intFromEnum(@field(script.Texture, rwst.texture));
                            f.textures[idx].compute_storage_read = true;
                            f.textures[idx].compute_storage_write = true;
                        }
                    }
                    for (cpass.readwrite_storage_buffers) |rw_buf| {
                        const idx = @intFromEnum(@field(script.StorageBuffer, rw_buf));
                        f.storage_buffers[idx].compute_storage_read = true;
                        f.storage_buffers[idx].compute_storage_write = true;
                    }
                    for (cpass.dispatches) |dispatch| {
                        for (dispatch.readonly_storage_textures) |ro_tex| {
                            const result = parseIndex(ro_tex) catch unreachable;
                            if (result) |r| {
                                @field(f, r.ref)[r.idx].compute_storage_read = true;
                            } else {
                                const idx = @intFromEnum(@field(script.Texture, ro_tex));
                                f.textures[idx].compute_storage_read = true;
                            }
                        }
                        for (dispatch.readonly_storage_buffers) |ro_buf| {
                            const idx = @intFromEnum(@field(script.StorageBuffer, ro_buf));
                            f.storage_buffers[idx].compute_storage_read = true;
                        }
                    }
                },
                .unroll => @compileError("Cannot use unroll in template"),
            };

            break :blk f;
        };
    };
}
