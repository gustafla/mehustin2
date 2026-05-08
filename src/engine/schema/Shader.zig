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

pub const ParamIterator = struct {
    shader: *const Shader,
    i: usize = 0,

    pub fn next(self: *ParamIterator) ?struct { []const u8, ?i32 } {
        if (self.i >= self.shader.params.len) return null;
        const param = self.shader.params[self.i];
        self.i += 1;
        const name, const val_str = std.mem.cutScalarLast(u8, param, '=') orelse
            return .{ param, null };
        const val = std.fmt.parseInt(i32, val_str, 10) catch
            return .{ name, null };
        return .{ name, val };
    }
};

pub fn paramIterator(self: *const Shader) ParamIterator {
    return .{ .shader = self };
}
