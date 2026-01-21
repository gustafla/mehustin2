const std = @import("std");

const c = @import("c.zig").c;

fn enumFieldNameFromC(
    comptime name: []const u8,
) [:0]u8 {
    // Convert to lowercase
    var buf: [name.len + 1]u8 = undefined;
    for (name, 0..) |chr, i| {
        buf[i] = std.ascii.toLower(chr);
    }

    buf[name.len] = 0;
    return buf[0..name.len :0];
}

pub fn EnumFromC(
    comptime type_name: []const u8,
    comptime opt: struct {
        prefix: []const u8 = "SDL_GPU",
        extra_fields: []const @Type(.enum_literal) = &.{},
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

    var fields: [c_decls.len]std.builtin.Type.EnumField = undefined;
    var index: usize = 0;
    var max_val: Tag = 0;

    // Search prefix: "SDL_GPU_VERTEXELEMENTFORMAT"
    const search_prefix = opt.prefix ++ "_" ++ variant;
    for (c_decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, search_prefix)) {
            const val = @field(c, decl.name);
            if (max_val < val) {
                max_val = val;
            }
            const raw_name = decl.name[search_prefix.len + 1 ..];
            fields[index] = .{
                .name = enumFieldNameFromC(raw_name),
                .value = val,
            };
            index += 1;
        }
    }

    for (opt.extra_fields) |extra| {
        max_val += 1;
        fields[index] = .{
            .name = @tagName(extra),
            .value = max_val,
        };
        index += 1;
    }

    // TODO: Change this to @Enum in 0.16
    return @Type(.{ .@"enum" = .{
        .decls = &.{},
        .tag_type = Tag,
        .fields = fields[0..index],
        .is_exhaustive = true,
    } });
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

pub const PrimitiveType = EnumFromC("PrimitiveType", .{});
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
    enable: bool = false,

    pub fn toSDL(self: @This()) c.SDL_GPUColorTargetBlendState {
        return .{
            .src_color_blendfactor = @intFromEnum(self.src_color),
            .dst_color_blendfactor = @intFromEnum(self.dst_color),
            .color_blend_op = @intFromEnum(self.color_op),
            .src_alpha_blendfactor = @intFromEnum(self.src_alpha),
            .dst_alpha_blendfactor = @intFromEnum(self.dst_alpha),
            .alpha_blend_op = @intFromEnum(self.alpha_op),
            .enable_blend = self.enable,
            .enable_color_write_mask = false,
        };
    }
};

pub const Filter = EnumFromC("Filter", .{});
pub const SamplerMipmapMode = EnumFromC("SamplerMipmapMode", .{});
pub const SamplerAddressMode = EnumFromC("SamplerAddressMode", .{});

pub const LoadOp = EnumFromC("LoadOp", .{});
pub const StoreOp = EnumFromC("StoreOp", .{});
