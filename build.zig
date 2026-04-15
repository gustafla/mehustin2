const std = @import("std");

// Hooks up module dependencies in the caller project's build graph.
pub fn importScript(d: *std.Build.Dependency, script_mod: *std.Build.Module) void {
    const engine_mod = d.module("engine");
    script_mod.addImport("engine", engine_mod);
    engine_mod.addImport("script", script_mod);
    d.module("render").addImport("script", script_mod);
    d.module("exe").addImport("script", script_mod);
}

/// Sets up glslc steps for all files in the caller project's "shaders" directory.
pub fn compileShaders(b: *std.Build, d: *std.Build.Dependency, config: anytype) void {
    const io = b.graph.io;
    const arena = b.graph.arena;

    // Create glsl compiler run step for each shader
    var shader_source_dir = b.build_root.handle.openDir(
        io,
        config.shader_dir,
        .{ .iterate = true },
    ) catch @panic("Can't open shader dir");
    var iter = shader_source_dir.iterate();
    while (iter.next(io) catch @panic("Can't iterate shader dir")) |entry| {
        if (entry.kind != .file) continue;

        // Init input and output paths
        const input_path = std.fs.path.join(
            arena,
            &.{ config.shader_dir, entry.name },
        ) catch @panic("OOM");
        const output_path = std.mem.concat(
            arena,
            u8,
            &.{ config.data_dir, "/", entry.name, ".spv" },
        ) catch @panic("OOM");

        // Create run step
        const shaderc_run = b.addSystemCommand(&.{
            "glslc",
            "-O",
            "-MD",
            "-MF",
        });

        _ = shaderc_run.addDepFileOutputArg("shader.d");
        shaderc_run.addPrefixedDirectoryArg("-I", b.path(config.shader_dir).path(b, "lib"));
        shaderc_run.addPrefixedDirectoryArg("-I", d.path("shader_lib"));

        // Add args from conf
        inline for (@typeInfo(@TypeOf(config)).@"struct".fields) |field| {
            const upper = comptime toUpper(field.name);
            switch (@typeInfo(field.type)) {
                .comptime_float, .comptime_int, .float, .int => {
                    shaderc_run.addArg(std.fmt.comptimePrint("-D{s}={}", .{
                        &upper, @field(config, field.name),
                    }));
                },
                .pointer => |ptr| {
                    if (ptr.size == .slice and ptr.child == u8) {
                        shaderc_run.addArg(std.fmt.comptimePrint("-D{s}={s}", .{
                            &upper, @field(config, field.name),
                        }));
                    }
                },
                else => {},
            }
        }

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
}

pub const PresentationMode = enum { vsync, mailbox };

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_name: []const u8,
    system_sdl: bool,
    render_dynlib: bool,
    show_fps: bool,
    present_mode: PresentationMode,
    udp_client: bool,

    pub fn init(b: *std.Build) @This() {
        const arena = b.graph.arena;

        // Use standard target options
        const target = b.standardTargetOptions(.{});

        // Use standard optimize options
        const optimize = b.standardOptimizeOption(.{});

        // Define build options
        return .{
            .target = target,
            .optimize = optimize,
            .exe_name = b.option(
                []const u8,
                "exe_name",
                "Executable file name",
            ) orelse if (!target.query.isNative()) blk: {
                const triple = target.result.linuxTriple(arena) catch @panic("OOM");
                break :blk std.mem.concat(arena, u8, &.{
                    "demo",
                    "-",
                    triple,
                }) catch @panic("OOM");
            } else "demo",
            .system_sdl = b.option(
                bool,
                "system_sdl",
                "Link with system SDL library",
            ) orelse (optimize == .Debug),
            .render_dynlib = b.option(
                bool,
                "render_dynlib",
                "Load (and enable reloading) render logic from librender.so",
            ) orelse (optimize == .Debug),
            .show_fps = b.option(
                bool,
                "show_fps",
                "Show FPS on the HUD",
            ) orelse (optimize == .Debug),
            .present_mode = b.option(
                PresentationMode,
                "present_mode",
                "Presentation mode",
            ) orelse .vsync,
            .udp_client = b.option(
                bool,
                "udp_client",
                "Send UDP packets to valot.instanssi.org",
            ) orelse false,
        };
    }

    pub fn createModule(self: *const @This(), bb: *std.Build) *std.Build.Module {
        const options_mod = bb.addOptions();
        options_mod.addOption(bool, "system_sdl", self.system_sdl);
        options_mod.addOption(bool, "render_dynlib", self.render_dynlib);
        options_mod.addOption(bool, "show_fps", self.show_fps);
        options_mod.addOption(PresentationMode, "present_mode", self.present_mode);
        options_mod.addOption(bool, "udp_client", self.udp_client);
        return options_mod.createModule();
    }
};

pub fn install(b: *std.Build, d: *std.Build.Dependency, options: Options) void {
    // Add data files to bin
    const install_data_dir = b.addInstallDirectory(.{
        .source_dir = b.path("data"),
        .install_dir = .bin,
        .install_subdir = "data",
    });
    b.getInstallStep().dependOn(&install_data_dir.step);

    // Test run of msdf-atlas-gen
    // const msdf = d.artifact("msdf-atlas-gen");
    // const msdf_run = b.addRunArtifact(msdf);
    // msdf_run.addArg("-font");
    // msdf_run.addFileArg(b.path("data/Inter-VariableFont_opsz,wght.ttf"));
    // msdf_run.addArg("-imageout");
    // const msdf_png = msdf_run.addOutputFileArg("atlas.png");
    // b.getInstallStep().dependOn(&b.addInstallBinFile(msdf_png, "data/atlas.png").step);

    // Add README.md to bin
    b.getInstallStep().dependOn(&b.addInstallBinFile(
        b.path("README.md"),
        "README.md",
    ).step);

    // Add THIRD-PARTY-LICENSES.md to bin
    b.getInstallStep().dependOn(&b.addInstallBinFile(
        d.path("vendor/LICENSES.md"),
        "THIRD-PARTY-LICENSES.md",
    ).step);

    // Set exe rpath
    const exe_mod = d.module("exe");
    const lib_path = b.getInstallPath(.lib, ".");
    exe_mod.addRPath(.{ .cwd_relative = lib_path });

    // Add exe to bin
    const exe = d.artifact(options.exe_name);
    b.installArtifact(exe);

    // Add lib to lib
    if (options.render_dynlib) {
        const render_lib = d.artifact("render");
        b.installArtifact(render_lib);
    }

    // Add run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(.{ .cwd_relative = b.exe_dir });
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);
}

pub fn build(b: *std.Build) void {
    const options = Options.init(b);
    const options_mod = options.createModule(b);

    // Get SDL3 dependency from build.zig.zon
    const sdl_dep = b.dependency("sdl", .{
        .target = options.target,
        .optimize = options.optimize,
        .preferred_linkage = .static,
        .strip = options.optimize != .Debug,
        .sanitize_c = .off,
    });

    // Get the stb dependency
    const stb_dep = b.dependency("stb", .{});

    // Get the par dependency
    const par_dep = b.dependency("par", .{});

    // Create a translate C step
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = options.target,
        .optimize = options.optimize,
    });
    if (options.system_sdl) {
        translate_c.linkSystemLibrary("SDL3", .{});
    } else {
        translate_c.addIncludePath(sdl_dep.path("include"));
    }
    translate_c.addIncludePath(stb_dep.path("."));
    translate_c.addIncludePath(par_dep.path("."));
    const translate_c_mod = translate_c.createModule();

    // Create a module for engine.zig
    const engine_mod = b.addModule("engine", .{
        .root_source_file = b.path("src/engine.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .strip = false,
        .sanitize_c = .off,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = translate_c_mod },
            .{ .name = "options", .module = options_mod },
        },
    });

    // Create a module for render.zig
    const render_mod = b.addModule("render", .{
        .root_source_file = b.path("src/render.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .strip = false,
        .sanitize_c = .off,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = translate_c_mod },
            .{ .name = "options", .module = options_mod },
            .{ .name = "engine", .module = engine_mod },
        },
    });

    // Create a module for main.zig
    const exe_mod = b.addModule("exe", .{
        .root_source_file = b.path("src/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.optimize != .Debug,
        .sanitize_c = .off,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = translate_c_mod },
            .{ .name = "options", .module = options_mod },
            .{ .name = "engine", .module = engine_mod },
        },
    });

    // Link SDL
    if (options.system_sdl) {
        engine_mod.linkSystemLibrary("SDL3", .{});
        render_mod.linkSystemLibrary("SDL3", .{});
        exe_mod.linkSystemLibrary("SDL3", .{});
    } else {
        const sdl_lib = sdl_dep.artifact("SDL3");
        engine_mod.linkLibrary(sdl_lib);
        render_mod.linkLibrary(sdl_lib);
        exe_mod.linkLibrary(sdl_lib);
    }

    // Add stb_vorbis to exe
    exe_mod.addIncludePath(stb_dep.path("."));
    exe_mod.addCSourceFile(.{ .file = stb_dep.path("stb_vorbis.c") });

    // Generate C files for C header libraries
    const c_write = b.addWriteFiles();
    const stb_image_c = c_write.add("stb_image.c",
        \\#define STB_IMAGE_IMPLEMENTATION
        \\#define STBI_NO_FAILURE_STRINGS
        \\#define STBI_ASSERT(x)
        \\#include <stb_image.h>
        \\
    );
    engine_mod.addIncludePath(stb_dep.path("."));
    engine_mod.addCSourceFile(.{ .file = stb_image_c });
    const stb_truetype_c = c_write.add("stb_truetype.c",
        \\#define STB_TRUETYPE_IMPLEMENTATION
        \\#include <stb_truetype.h>
        \\
    );
    engine_mod.addCSourceFile(.{ .file = stb_truetype_c });
    const par_shapes_c = c_write.add("par_shapes.c",
        \\#define PAR_SHAPES_IMPLEMENTATION
        \\#include <par_shapes.h>
        \\
    );
    engine_mod.addIncludePath(par_dep.path("."));
    engine_mod.addCSourceFile(.{ .file = par_shapes_c });

    // Set up render shared library
    if (options.render_dynlib) {
        const render = b.addLibrary(.{
            .name = "render",
            .linkage = .dynamic,
            .root_module = render_mod,
        });
        b.installArtifact(render);
    }

    // Add the main exe
    const exe = b.addExecutable(.{
        .name = options.exe_name,
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Add msdf-atlas-gen
    const msdf_dep = b.dependency("msdf_atlas_gen", .{});
    const msdf_atlas_gen = msdf_dep.artifact("msdf-atlas-gen");
    b.installArtifact(msdf_atlas_gen);
}

fn toUpper(comptime str: []const u8) [str.len]u8 {
    var buf: [str.len]u8 = undefined;
    for (&buf, str) |*u, c| {
        u.* = std.ascii.toUpper(c);
    }
    return buf;
}
