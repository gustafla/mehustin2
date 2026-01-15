const std = @import("std");
const Build = std.Build;

const config = @import("src/config.zon");

const log = std.log.scoped(.build);

pub fn build(b: *Build) void {
    // Use standard target options
    const target = b.standardTargetOptions(.{});

    // Use standard optimize options
    const optimize = b.standardOptimizeOption(.{});

    // Define variable for release setting
    const release_build = optimize != .Debug;
    const lto: std.zig.LtoMode = if (release_build) .full else .none;

    // Define build options
    const system_sdl = b.option(
        bool,
        "system-sdl",
        "Link with system SDL library",
    ) orelse !release_build;
    const render_dynlib = b.option(
        bool,
        "render-dynlib",
        "Load (and enable reloading) render logic from librender.so",
    ) orelse !release_build;
    const options = b.addOptions();
    options.addOption(bool, "system_sdl", system_sdl);
    options.addOption(bool, "render_dynlib", render_dynlib);
    options.addOption([]const u8, "data_dir", b.getInstallPath(.bin, config.data_dir));

    // Get SDL3 dependency from build.zig.zon
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .preferred_linkage = .static,
        .strip = release_build,
        .lto = lto,
    });
    const sdl_lib = sdl_dep.artifact("SDL3");

    // Create a module for main.zig
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = release_build,
    });

    // Create a module for render.zig
    const render_mod = b.createModule(.{
        .root_source_file = b.path("src/render.zig"),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });

    // Export build options defined earlier into modules
    exe_mod.addOptions("options", options);

    // Link SDL
    if (system_sdl) {
        exe_mod.linkSystemLibrary("SDL3", .{});
        render_mod.linkSystemLibrary("SDL3", .{});
    } else {
        exe_mod.linkLibrary(sdl_lib);
        render_mod.linkLibrary(sdl_lib);
    }

    // Get the stb dependency from build.zig.zon
    const stb_dep = b.dependency("stb", .{});
    exe_mod.addIncludePath(stb_dep.path("."));
    render_mod.addIncludePath(stb_dep.path("."));

    // Add stb_vorbis to exe
    exe_mod.addCSourceFile(.{ .file = stb_dep.path("stb_vorbis.c") });

    // Generate stb_image.c, stb_truetype.c
    const stb_write = b.addWriteFiles();
    const stb_image_c = stb_write.add("stb_image.c",
        \\#define STB_IMAGE_IMPLEMENTATION
        \\#define STBI_NO_FAILURE_STRINGS
        \\#define STBI_ASSERT(x)
        \\#include <stb_image.h>
        \\
    );
    const stb_truetype_c = stb_write.add("stb_truetype.c",
        \\#define STB_TRUETYPE_IMPLEMENTATION
        \\#include <stb_truetype.h>
        \\
    );

    // Set up render shared library
    if (render_dynlib) {
        const lib_path = b.getInstallPath(.lib, ".");
        exe_mod.addRPath(.{ .cwd_relative = lib_path });

        render_mod.addOptions("options", options);
        render_mod.addCSourceFile(.{ .file = stb_image_c });
        render_mod.addCSourceFile(.{ .file = stb_truetype_c });

        const render = b.addLibrary(.{
            .name = "render",
            .linkage = .dynamic,
            .root_module = render_mod,
        });
        render.linkLibC();
        b.installArtifact(render);
    } else {
        exe_mod.addCSourceFile(.{ .file = stb_image_c });
        exe_mod.addCSourceFile(.{ .file = stb_truetype_c });
    }

    // Add target triple to executable name if target isn't native
    const exe_name_base = "demo";
    const exe_name = if (!target.query.isNative()) blk: {
        const triple = target.result.linuxTriple(b.allocator) catch @panic("OOM");
        break :blk std.mem.concat(b.allocator, u8, &.{
            exe_name_base,
            "-",
            triple,
        }) catch @panic("OOM");
    } else exe_name_base;

    // Add the main exe
    const exe = b.addExecutable(.{
        .name = exe_name,
        .root_module = exe_mod,
    });
    exe.linkLibC();
    exe.lto = lto;
    b.installArtifact(exe);

    // Create glsl compiler run step for each shader
    var shader_source_dir = b.build_root.handle.openDir(
        config.shader_dir,
        .{ .iterate = true },
    ) catch @panic("Can't open shader dir");
    var iter = shader_source_dir.iterate();
    while (iter.next() catch @panic("Can't iterate shader dir")) |entry| {
        if (entry.kind != .file) continue;

        // Init input and output paths
        const input_path = std.fs.path.join(
            b.allocator,
            &.{ config.shader_dir, entry.name },
        ) catch @panic("OOM");
        const output_path = std.mem.concat(
            b.allocator,
            u8,
            &.{ config.data_dir, "/", entry.name, ".spv" },
        ) catch @panic("OOM");

        // Create run step
        const shaderc_run = b.addSystemCommand(&.{
            "glslc",
            "-O",
            std.fmt.comptimePrint("-DWIDTH={}", .{config.width}),
            std.fmt.comptimePrint("-DHEIGHT={}", .{config.height}),
        });
        shaderc_run.addPrefixedDirectoryArg("-I", b.path(config.shader_dir));
        const shaderc_output = shaderc_run.addPrefixedOutputFileArg("-o", output_path);
        shaderc_run.addFileArg(b.path(input_path));

        // Create install step
        const shader_install = b.addInstallBinFile(
            shaderc_output,
            output_path,
        );
        shader_install.step.dependOn(&shaderc_run.step);
        b.getInstallStep().dependOn(&shader_install.step);
    }

    // Setup docs generation
    const install_docs = b.addInstallDirectory(.{
        .install_dir = .prefix,
        .install_subdir = "docs",
        .source_dir = exe.getEmittedDocs(),
    });
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);

    // Add data files to bin
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path(config.data_dir),
        .install_dir = .bin,
        .install_subdir = config.data_dir,
    }).step);

    // Add README to bin
    b.getInstallStep().dependOn(&b.addInstallBinFile(
        b.path("README-RELEASE.md"),
        "README.md",
    ).step);

    // Create a Run step in the build graph
    const run_cmd = b.addRunArtifact(exe);
    // Install the build artifacts when `zig build run`
    run_cmd.step.dependOn(b.getInstallStep());

    // Allow the user to pass arguments to the application
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step (`zig build run`).
    // It will be visible in the `zig build --help` menu.
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);
}
