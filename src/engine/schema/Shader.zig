const std = @import("std");
const Allocator = std.mem.Allocator;

const default_file = "shaders.glsl";
const default_entrypoint = "main";

file: []const u8 = default_file,
entrypoint: []const u8 = default_entrypoint,

const Shader = @This();

pub const Graphics = union(enum) {
    file: []const u8, // Implies default_entrypoint
    entrypoint: []const u8, // Implies default_file
    stages: Stages,

    pub const Stages = struct {
        vert: Shader = .{ .file = "tri.vert", .entrypoint = default_entrypoint },
        frag: Shader,
    };

    /// Special function, will be called by render.compiler.serialize
    pub fn resolve(self: @This()) Stages {
        return switch (self) {
            .file => |name| .{
                .vert = .{ .file = name, .entrypoint = default_entrypoint },
                .frag = .{ .file = name, .entrypoint = default_entrypoint },
            },
            .entrypoint => |name| .{
                .vert = .{ .file = default_file, .entrypoint = name },
                .frag = .{ .file = default_file, .entrypoint = name },
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
        threads: struct {
            core: Vec,
            apron: struct { x: u32 = 0, y: u32 = 0, z: u32 = 0 } = .{},
        },
        groups: union(enum) {
            vec: Vec,
            vec_by_core: Vec,
            resolution_by_core,
        },

        pub fn resolve(self: @This()) struct { threads: Vec, groups: Vec } {
            const core = self.threads.core;
            return .{
                .threads = .{
                    .x = core.x + self.threads.apron.x * 2,
                    .y = core.y + self.threads.apron.y * 2,
                    .z = core.z + self.threads.apron.z * 2,
                },
                .groups = switch (self.groups) {
                    .vec => |v| v,
                    .vec_by_core => |v| .{
                        .x = (v.x + core.x - 1) / core.x,
                        .y = (v.y + core.y - 1) / core.y,
                        .z = (v.z + core.z - 1) / core.z,
                    },
                    .resolution_by_core => .{
                        .x = (config.width + core.x - 1) / core.x,
                        .y = (config.height + core.y - 1) / core.y,
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
) Allocator.Error![]const u8 {
    if (threads) |t| {
        return std.fmt.allocPrint(arena, "{s}.{s}.{s}.{}.{}.{}.spv", .{
            self.file, @tagName(stage), self.entrypoint, t.x, t.y, t.z,
        });
    } else {
        return std.fmt.allocPrint(arena, "{s}.{s}.{s}.spv", .{
            self.file, @tagName(stage), self.entrypoint,
        });
    }
}
