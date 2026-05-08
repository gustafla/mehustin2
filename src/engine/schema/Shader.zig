const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

file: []const u8,
params: []const []const u8 = &.{},

const Shader = @This();

pub const Graphics = union(enum) {
    all: Shader,
    stages: Stages,

    pub const Stages = struct {
        vert: Shader = .{ .file = "tri.vert" },
        frag: Shader,
    };

    /// Special function, will be called by render.compiler.serialize
    pub fn resolve(self: @This()) Stages {
        return switch (self) {
            .all => |all| .{
                .vert = all,
                .frag = all,
            },
            .stages => |stages| stages,
        };
    }
};

pub const Stage = enum {
    vertex,
    fragment,
    compute,
};

pub fn Dimensions(config: anytype) type {
    return struct {
        threads: Vec,
        groups: union(enum) {
            vec: Vec,
            vec_by_threads: Vec,
            resolution_by_threads,
        },

        pub fn resolve(self: @This()) struct { threads: Vec, groups: Vec } {
            return .{
                .threads = self.threads,
                .groups = switch (self.groups) {
                    .vec => |v| v,
                    .vec_by_threads => |v| .{
                        .x = (v.x + self.threads.x - 1) / self.threads.x,
                        .y = (v.y + self.threads.y - 1) / self.threads.y,
                        .z = (v.z + self.threads.z - 1) / self.threads.z,
                    },
                    .resolution_by_threads => .{
                        .x = (config.width + self.threads.x - 1) / self.threads.x,
                        .y = (config.height + self.threads.y - 1) / self.threads.y,
                        .z = 1,
                    },
                },
            };
        }
    };
}

const Vec = struct {
    x: u32,
    y: u32 = 1,
    z: u32 = 1,
};

pub fn spvFilename(
    self: @This(),
    arena: Allocator,
    stage: Stage,
    threads: ?Vec,
) Writer.Error![]const u8 {
    var alloc_writer: Writer.Allocating = .init(arena);
    const writer = &alloc_writer.writer;
    try writer.print("{s}.{s}", .{ self.file, @tagName(stage) });
    for (self.params) |param| {
        try writer.print(".{s}", .{param});
    }
    if (threads) |t| {
        try writer.print(".{}.{}.{}", .{ t.x, t.y, t.z });
    }
    try writer.writeAll(".spv");
    return alloc_writer.written();
}

pub const ParamValue = union(enum) {
    int: i32,
    ivec2: [2]i32,
    ivec3: [3]i32,
    ivec4: [4]i32,
    float: f32,
    vec2: [2]f32,
    vec3: [3]f32,
    vec4: [4]f32,
    string: []const u8,

    pub fn parse(str: []const u8) error{InvalidParam}!@This() {
        if (std.fmt.parseInt(i32, str, 10)) |val| return .{ .int = val } else |_| {}
        if (std.fmt.parseFloat(f32, str)) |val| return .{ .float = val } else |_| {}
        if (str.len >= 2 and str[0] == '"' and str[str.len - 1] == '"')
            return .{ .string = str[1 .. str.len - 1] };

        inline for (@typeInfo(@This()).@"union".fields) |field| {
            comptime if (@typeInfo(field.type) != .array) continue;

            if (str.len > field.name.len and std.mem.startsWith(u8, str, field.name)) {
                if (str[field.name.len] != '(' or str[str.len - 1] != ')') return error.InvalidParam;

                var buf: field.type = undefined;
                var i: usize = 0;

                var iterator = std.mem.splitScalar(u8, str[field.name.len + 1 .. str.len - 1], ',');

                while (iterator.next()) |item| {
                    if (i >= buf.len) return error.InvalidParam;

                    const trimmed = std.mem.trim(u8, item, &.{ ' ', '\t' });
                    if (trimmed.len == 0) return error.InvalidParam;

                    const Child = @typeInfo(field.type).array.child;
                    buf[i] = switch (Child) {
                        i32 => std.fmt.parseInt(i32, trimmed, 10) catch return error.InvalidParam,
                        f32 => std.fmt.parseFloat(f32, trimmed) catch return error.InvalidParam,
                        else => @compileError("Unparsed array child type"),
                    };

                    i += 1;
                }

                if (i != buf.len) return error.InvalidParam;

                return @unionInit(@This(), field.name, buf);
            }
        }
        return error.InvalidParam;
    }
};

pub const ParamIterator = struct {
    shader: *const Shader,
    i: usize = 0,

    pub fn next(self: *ParamIterator) ?struct { []const u8, ?[]const u8 } {
        if (self.i >= self.shader.params.len) return null;
        const param = self.shader.params[self.i];
        self.i += 1;
        return if (std.mem.cutScalarLast(u8, param, '=')) |s| s else .{ param, null };
    }
};

pub fn paramIterator(self: *const Shader) ParamIterator {
    return .{ .shader = self };
}
