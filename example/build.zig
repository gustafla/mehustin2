const std = @import("std");
const engine = @import("mehustin2");

pub fn build(b: *std.Build) void {
    // Initialize options and dependency
    const options = engine.Options.init(b);
    const engine_dep = b.dependency("mehustin2", options);

    // Create script module
    const script_mod = b.createModule(.{
        .root_source_file = b.path("src/script.zig"),
    });

    // Hook up module dependencies
    engine.importScript(engine_dep, script_mod);

    // Compile and install shaders
    engine.compileShaders(
        b,
        engine_dep,
        @import("src/render.zon"),
        @import("src/config.zon"),
    );

    // Install the build artifacts
    engine.install(b, engine_dep, options);
}
