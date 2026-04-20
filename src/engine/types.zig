const std = @import("std");

const c = @import("c");

const math = @import("math.zig");
const timeline = @import("timeline.zig");

pub fn EnumFromC(
    comptime type_name: []const u8,
    comptime opt: struct {
        prefix: []const u8 = "SDL_GPU",
        extra_fields: []const @EnumLiteral() = &.{},
    },
) type {
    @setEvalBranchQuota(100000);
    const Tag = @field(c, opt.prefix ++ type_name);
    const c_decls = @typeInfo(c).@"struct".decls;

    // Type name: "VertexElementFormat"
    // Variant: "VERTEXELEMENTFORMAT"
    var variant: [type_name.len]u8 = undefined;
    for (type_name, 0..) |chr, i| {
        variant[i] = std.ascii.toUpper(chr);
    }

    var field_names: [c_decls.len][]const u8 = undefined;
    var field_values: [c_decls.len]Tag = undefined;
    var index: usize = 0;
    var max_val: Tag = 0;

    // Buffer for lowercased field names
    var string_buf: [1024 * 16]u8 = undefined;
    var string_cursor: usize = 0;

    // Search prefix: "SDL_GPU_VERTEXELEMENTFORMAT"
    const search_prefix = opt.prefix ++ "_" ++ variant;
    for (c_decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, search_prefix)) {
            const val = @field(c, decl.name);
            if (max_val < val) {
                max_val = val;
            }
            const raw_name = decl.name[search_prefix.len + 1 ..];

            const string_start = string_cursor;
            for (raw_name) |chr| {
                string_buf[string_cursor] = std.ascii.toLower(chr);
                string_cursor += 1;
            }
            field_names[index] = string_buf[string_start..string_cursor];
            field_values[index] = val;

            index += 1;
        }
    }

    for (opt.extra_fields) |extra| {
        max_val += 1;
        field_names[index] = @tagName(extra);
        field_values[index] = max_val;
        index += 1;
    }

    return @Enum(Tag, .exhaustive, field_names[0..index], field_values[0..index]);
}

pub fn FlagsFromC(
    comptime type_name: []const u8,
    comptime opt: struct {
        prefix: []const u8 = "SDL_GPU",
    },
) type {
    @setEvalBranchQuota(100000);
    const Backing = @field(c, opt.prefix ++ type_name ++ "Flags");
    const c_decls = @typeInfo(c).@"struct".decls;

    // Type name: "TextureUsage"
    // Variant: "TEXTUREUSAGE"
    var variant: [type_name.len]u8 = undefined;
    for (type_name, 0..) |chr, i| {
        variant[i] = std.ascii.toUpper(chr);
    }

    var field_names_raw: [c_decls.len][]const u8 = undefined;
    var total_len: usize = 0;
    var index: usize = 0;

    // Search prefix: "SDL_GPU_TEXTUREUSAGE"
    const search_prefix = opt.prefix ++ "_" ++ variant;
    for (c_decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, search_prefix)) {
            field_names_raw[index] = decl.name;
            total_len += decl.name.len;
            index += 1;
        }
    }

    // Buffer for lowercased field names
    var string_buf: [total_len]u8 = undefined;
    var string_cursor: usize = 0;
    var names: [@bitSizeOf(Backing)][]const u8 = undefined;

    for (field_names_raw[0..index], 0..) |name_raw, i| {
        // Assert C value is a power of two in sequence
        std.debug.assert(@field(c, name_raw) == (1 << i));

        const trimmed = name_raw[search_prefix.len + 1 ..];
        const lowercased = string_buf[string_cursor..][0..trimmed.len];
        string_cursor += trimmed.len;
        for (trimmed, 0..) |chr, j| {
            lowercased[j] = std.ascii.toLower(chr);
        }
        names[i] = lowercased;
    }

    for (index..@bitSizeOf(Backing)) |i| {
        names[i] = std.fmt.comptimePrint("padding{}", .{i});
    }

    return @Struct(.@"packed", Backing, &names, &@splat(bool), &@splat(.{}));
}

pub const VertexFormat = EnumFromC("VertexElementFormat", .{});

pub fn vertexFormatLen(format: VertexFormat) u32 {
    return switch (format) {
        .invalid => unreachable,
        inline else => |tag| comptime blk: {
            @setEvalBranchQuota(10000);
            const name = @tagName(tag);

            var index: usize = 0;
            while (index < name.len and std.ascii.isAlphabetic(name[index])) {
                index += 1;
            }

            const scalar_str = name[0..index];
            const Scalar = enum { byte, ubyte, short, ushort, half, int, uint, float };
            const scalar_tag = std.meta.stringToEnum(Scalar, scalar_str) orelse unreachable;

            const scalar_len = switch (scalar_tag) {
                .byte, .ubyte => 1,
                .short, .ushort, .half => 2,
                .int, .uint, .float => 4,
            };

            const count: u32 = if (index < name.len and std.ascii.isDigit(name[index]))
                name[index] - '0'
            else
                1;

            break :blk scalar_len * count;
        },
    };
}

pub const TextureFormat = EnumFromC(
    "TextureFormat",
    .{ .extra_fields = &.{.swapchain} },
);
pub const TextureType = EnumFromC("TextureType", .{});
pub const TextureUsageFlags = FlagsFromC("TextureUsage", .{});

pub const TextureInfo = struct {
    tex_type: TextureType = .@"2d",
    format: TextureFormat,
    width: u32,
    height: u32,
    depth: u32 = 1,
    mip_levels: u32 = 1,
};

pub const BufferInfo = struct {
    num_elements: u32,
    first_element: u32 = 0,
};

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

pub const FrameUniforms = struct {
    vertex: VertexUniforms,
    fragment: FragmentUniforms,
};

pub const ShaderStage = EnumFromC("ShaderStage", .{});
pub const PrimitiveType = EnumFromC("PrimitiveType", .{});
pub const FillMode = EnumFromC("FillMode", .{});
pub const CullMode = EnumFromC("CullMode", .{});
pub const FrontFace = EnumFromC("FrontFace", .{});

pub const RasterizerState = struct {
    fill_mode: FillMode = .fill,
    cull_mode: CullMode = .back,
    front_face: FrontFace = .counter_clockwise,
    depth_bias_constant_factor: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_bias_slope_factor: f32 = 0,
    enable_depth_bias: bool = false,
    enable_depth_clip: bool = true,

    pub fn toSDL(self: @This()) c.SDL_GPURasterizerState {
        return .{
            .fill_mode = @intFromEnum(self.fill_mode),
            .cull_mode = @intFromEnum(self.cull_mode),
            .front_face = @intFromEnum(self.front_face),
            .depth_bias_constant_factor = self.depth_bias_constant_factor,
            .depth_bias_clamp = self.depth_bias_clamp,
            .depth_bias_slope_factor = self.depth_bias_slope_factor,
            .enable_depth_bias = self.enable_depth_bias,
            .enable_depth_clip = self.enable_depth_clip,
        };
    }
};

pub const CompareOp = EnumFromC("CompareOp", .{});
pub const BlendFactor = EnumFromC("BlendFactor", .{});
pub const BlendOp = EnumFromC("BlendOp", .{});

pub const BlendState = struct {
    src_color: BlendFactor = .src_alpha,
    dst_color: BlendFactor = .one_minus_src_alpha,
    color_op: BlendOp = .add,
    src_alpha: BlendFactor = .one,
    dst_alpha: BlendFactor = .one_minus_src_alpha,
    alpha_op: BlendOp = .add,
    color_write_mask: u8 = 0,
    enable: bool = false,
    enable_color_write_mask: bool = false,

    pub fn toSDL(self: @This()) c.SDL_GPUColorTargetBlendState {
        return .{
            .src_color_blendfactor = @intFromEnum(self.src_color),
            .dst_color_blendfactor = @intFromEnum(self.dst_color),
            .color_blend_op = @intFromEnum(self.color_op),
            .src_alpha_blendfactor = @intFromEnum(self.src_alpha),
            .dst_alpha_blendfactor = @intFromEnum(self.dst_alpha),
            .alpha_blend_op = @intFromEnum(self.alpha_op),
            .color_write_mask = self.color_write_mask,
            .enable_blend = self.enable,
            .enable_color_write_mask = self.enable_color_write_mask,
        };
    }
};

pub const Filter = EnumFromC("Filter", .{});
pub const SamplerMipmapMode = EnumFromC("SamplerMipmapMode", .{});
pub const SamplerAddressMode = EnumFromC("SamplerAddressMode", .{});

pub const LoadOp = EnumFromC("LoadOp", .{});
pub const StoreOp = EnumFromC("StoreOp", .{});

pub const SampleCount = EnumFromC("SampleCount", .{});
