const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout();
    const fwriter = stdout.writer(init.io, &buffer);
    const writer = fwriter.interface;

    inline for (@typeInfo(@This()).@"struct".decls) |namespaces| {
        const namespace = @field(@This(), namespaces.name);
        const T = @TypeOf(namespace);
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (info.decls) |decl| {
                const item = @field(namespace, decl.name);
                try serializeGlsl(writer, namespace.name, decl.name, item);
            },
            else => {},
        }
    }

    try writer.flush();
}

fn serializeGlsl(
    writer: std.Io.Writer,
    namespace: []const u8,
    decl: []const u8,
    item: anytype,
) !void {
    const T = @TypeOf(item);
    const is_array, const C, const value = switch (@typeInfo(T)) {
        .array => |info| .{ true, info.child, item },
        .@"fn" => |info| blk: {
            if (info.params.len > 0) return error.TooManyParameters;
            const RT = info.return_type orelse return error.NoReturnType;
            break :blk switch (@typeInfo(RT)) {
                .array => |rt_info| .{ true, rt_info.child, item() },
                else => .{ false, RT, item() },
            };
        },
        else => .{ false, T, item },
    };

    const glsl_type = switch (@typeInfo(C)) {
        .float, .comptime_float => "float",
        .int, .comptime_int => "int",
        else => return error.UnsupportedType,
    };

    try writer.writeAll("const ");
    try writer.writeAll(glsl_type);
    try writer.writeByte(' ');
    try writer.writeAll(namespace);
    try writer.writeByte('_');
    try writer.writeAll(decl);
    if (is_array) {
        try writer.print("[{}]", .{value.len});
    }
    try writer.writeAll(" = ");
    if (is_array) {
        try writer.writeAll(glsl_type);
        try writer.print("[{}]", .{value.len});
        try writer.writeByte('(');
        if (value.len > 0) {
            try writer.print("{}", .{value[0]});
            for (value[1..]) |n| {
                try writer.print(", {}", .{n});
            }
        }
        try writer.writeByte(')');
    } else {
        try writer.print("{}", .{value});
    }
    try writer.writeAll(";\n");
}
