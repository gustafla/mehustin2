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
