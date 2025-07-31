const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = struct {
    const PATH = "src/config.zon";

    data_dir: []const u8,
    shader_dir: []const u8,

    fn init(alloc: Allocator) !Config {
        std.log.info("Loading {s}", .{PATH});
        const file = try std.fs.cwd().openFile(PATH, .{});
        defer file.close();
        const stat = try file.stat();
        const buffer = try alloc.allocSentinel(u8, stat.size, 0);
        std.debug.assert(try file.readAll(buffer[0..]) == stat.size);
        return try std.zon.parse.fromSlice(Config, alloc, buffer, null, .{ .ignore_unknown_fields = true });
    }
};

var config: Config = undefined;

pub fn build(b: *std.Build) void {
    // Load config
    config = Config.init(b.allocator) catch @panic("Can't load " ++ Config.PATH);

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
        std.log.warn("-Dcompile-shaders is disabled and -Duse-shaderc is disabled. Shaders will not be compiled.", .{});
    }

    // Get SDL3 dependency from build.zig.zon
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

    // Get the stb dependency from build.zig.zon
    const stb_dep = b.dependency("stb", .{});
    exe_mod.addIncludePath(stb_dep.path("."));
    exe_mod.addCSourceFile(.{ .file = stb_dep.path("stb_vorbis.c") });

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
        compileShaders(b);
    }

    // Add data files to bin
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path(config.data_dir),
        .install_dir = .bin,
        .install_subdir = config.data_dir,
    }).step);

    // Add README to bin
    b.getInstallStep().dependOn(&b.addInstallBinFile(b.path("README-RELEASE.md"), "README.md").step);

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

fn compileShaders(b: *std.Build) void {
    const compile_shaders_mod = b.createModule(.{
        .root_source_file = b.path("src/shader/compiler.zig"),
        .target = b.resolveTargetQuery(.{}), // Native
        .optimize = .Debug,
    });
    compile_shaders_mod.linkSystemLibrary("shaderc", .{});
    const compile_shaders_exe = b.addExecutable(.{
        .name = "shader_compiler",
        .root_module = compile_shaders_mod,
    });
    compile_shaders_exe.linkLibC();

    // Create compiler run step for each shader
    var source_dir = std.fs.cwd().openDir(config.shader_dir, .{ .iterate = true }) catch @panic("Can't open shader dir");
    defer source_dir.close();
    var iter = source_dir.iterate();
    while (iter.next() catch @panic("Can't iterate shader dir")) |entry| {
        if (entry.kind != .file) continue;
        //Define input and output paths
        const input_path = std.fs.path.join(b.allocator, &[_][]const u8{ config.shader_dir, entry.name }) catch @panic("OOM");
        const compile_shaders_run = b.addRunArtifact(compile_shaders_exe);
        const compile_shaders_output = compile_shaders_run.addPrefixedOutputDirectoryArg("-o", config.shader_dir);
        compile_shaders_run.addFileArg(b.path(input_path));

        // Create install step
        const shader_install = b.addInstallDirectory(.{
            .source_dir = compile_shaders_output,
            .install_dir = .bin,
            .install_subdir = config.data_dir,
        });
        shader_install.step.dependOn(&compile_shaders_run.step);
        b.getInstallStep().dependOn(&shader_install.step);
    }
}
