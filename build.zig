const std = @import("std");

pub fn build(b: *std.Build) void {
    // Use standard target options
    const target = b.standardTargetOptions(.{});

    // Use standard optimize options
    const optimize = b.standardOptimizeOption(.{});

    // Define variable for release setting
    const release_build = optimize != .Debug;

    // Define build options
    const options = b.addOptions();
    const compile_shaders = b.option(bool, "compile-shaders", "Compile shaders at build time (requires shaderc)") orelse false;
    const use_shaderc = b.option(bool, "use-shaderc", "Compile shaders at runtime (requires shaderc)") orelse !release_build;
    options.addOption(bool, "use_shaderc", use_shaderc);

    if (!compile_shaders and !use_shaderc) {
        std.log.warn("Not using runtime shaderc but also compile_shaders is disabled. Shaders won't be built.", .{});
    }

    // Add SDL3 dependency
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
        .strip = release_build,
        //.install_build_config_h = false,
    });
    const sdl_lib = sdl_dep.artifact("SDL3");
    //sdl_lib.lto = if (release_build) .full else null;
    sdl_lib.want_lto = release_build;

    // Create a module for main.zig
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = release_build,
    });

    // Export build options defined earlier into the executable module
    exe_mod.addOptions("options", options);

    // Link SDL
    exe_mod.linkLibrary(sdl_lib);

    // Link shaderc
    if (use_shaderc) {
        exe_mod.linkSystemLibrary("shaderc", .{});
    }

    // Build the main.zig exe
    const exe = b.addExecutable(.{
        .name = "mehustin2",
        .root_module = exe_mod,
    });
    exe.linkLibC();
    // exe.lto = if (release_build) .full else null;
    exe.want_lto = release_build;

    // Configure the executable to be installed
    b.installArtifact(exe);

    // Add shader compilation to the build graph if requested
    if (compile_shaders) {
        const compile_shaders_mod = b.createModule(.{
            .root_source_file = b.path("./compile_shaders.zig"),
            .target = b.resolveTargetQuery(.{}), // Native
            .optimize = .Debug,
        });
        compile_shaders_mod.linkSystemLibrary("shaderc", .{});
        const compile_shaders_exe = b.addExecutable(.{
            .name = "compile_shaders",
            .root_module = compile_shaders_mod,
        });
        compile_shaders_exe.linkLibC();
        const compile_shaders_run = b.addRunArtifact(compile_shaders_exe);
        b.getInstallStep().dependOn(&compile_shaders_run.step);
    }

    // Create a Run step in the build graph
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Allow the user to pass arguments to the application
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu.
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
