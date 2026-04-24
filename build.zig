const std = @import("std");

const Shader = @import("src/engine/schema/Shader.zig");
const Font = @import("src/engine/schema/Font.zig");

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
                const triple = target.result.linuxTriple(b.allocator) catch @panic("OOM");
                break :blk std.mem.concat(b.allocator, u8, &.{
                    "demo",
                    "-",
                    triple,
                }) catch @panic("OOM");
            } else "demo",
            .system_sdl = b.option(
                bool,
                "system_sdl",
                "Link with system dynamic SDL library",
            ) orelse false,
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
        .strip = options.optimize != .Debug,
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
        .strip = options.optimize != .Debug,
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

    // Add default script, so that builds succeed (override with importScript)
    addScript(engine_mod, render_mod, exe_mod, b.createModule(.{
        .root_source_file = b.path("example/src/script.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.optimize != .Debug,
        .sanitize_c = .off,
        .link_libc = true,
    }));

    // Link SDL
    if (options.system_sdl) {
        engine_mod.linkSystemLibrary("SDL3", .{});
    } else {
        const sdl_lib = sdl_dep.artifact("SDL3");
        engine_mod.linkLibrary(sdl_lib);
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

// Hooks up module dependencies in the caller project's build graph.
pub fn importScript(d: *std.Build.Dependency, script_mod: *std.Build.Module) void {
    const engine_mod = d.module("engine");
    const render_mod = d.module("render");
    const exe_mod = d.module("exe");
    addScript(engine_mod, render_mod, exe_mod, script_mod);
}

/// Sets up glslc steps for all shader combinations in the caller project's render.zon
pub fn compileShaders(
    b: *std.Build,
    d: *std.Build.Dependency,
    comptime config: anytype,
) void {
    // Load and parse render.zon at runtime
    const render = parseZon(struct { passes: []const union(enum) {
        render: struct { drawcalls: []const struct {
            pipelines: []const struct {
                shader: Shader.Graphics,
            },
        } },
        compute: struct { dispatches: []const struct {
            comp: Shader,
        } },
    } }, b, "src/render.zon");

    // Load and parse timeline.zon at runtime
    const timeline = parseZon(struct {
        tags: []const struct { name: []const u8 },
    }, b, "src/timeline.zon");

    // Find tag indices
    var tag_set: std.StringHashMapUnmanaged(u32) = .empty;
    for (timeline.tags) |tag| {
        const num_tags = tag_set.count();
        _ = tag_set.getOrPutValue(b.allocator, tag.name, num_tags) catch @panic("OOM");
    }

    // Traverse the render.zon tree
    for (render.passes) |pass| {
        switch (pass) {
            .render => |rpass| for (rpass.drawcalls) |draw| {
                for (draw.pipelines) |pipe| {
                    const stages = pipe.shader.resolve();
                    compileShader(b, d, stages.vert, .vertex, config, &tag_set);
                    compileShader(b, d, stages.frag, .fragment, config, &tag_set);
                }
            },
            .compute => |cpass| for (cpass.dispatches) |disp| {
                compileShader(b, d, disp.comp, .compute, config, &tag_set);
            },
        }
    }
}

pub fn bakeFontAtlases(
    b: *std.Build,
    d: *std.Build.Dependency,
    comptime config: anytype,
) void {
    const arena = b.allocator;
    const msdf_atlas_gen = d.artifact("msdf-atlas-gen");

    // Load and parse timeline.zon at runtime
    const timeline = parseZon(struct {
        text: struct {
            fonts: []const Font,
        },
    }, b, "src/timeline.zon");

    for (timeline.text.fonts, 0..) |font, i| {
        const input_path = b.pathJoin(&.{ config.font_dir, font.file });
        const output_path = b.pathJoin(&.{ config.data_dir, b.fmt("font{}", .{i}) });
        const output_path_json = b.fmt("{s}.json", .{output_path});
        const output_path_png = b.fmt("{s}.png", .{output_path});

        const msdf_run = b.addRunArtifact(msdf_atlas_gen);
        msdf_run.setCwd(b.path("."));
        msdf_run.addFileInput(b.path(input_path));
        if (font.variables.len == 0) {
            msdf_run.addArgs(&.{ "-font", input_path });
        } else {
            const variables = std.mem.join(arena, "&", font.variables) catch @panic("OOM");
            const spec = b.fmt("{s}?{s}", .{ input_path, variables });
            msdf_run.addArgs(&.{ "-varfont", spec });
        }
        msdf_run.addArgs(&.{ "-type", "mtsdf" });
        msdf_run.addArg("-potr");
        msdf_run.addArgs(&.{ "-size", b.fmt("{}", .{font.size}) });
        msdf_run.addArgs(&.{ "-empadding", b.fmt("{}", .{font.padding_em}) });

        msdf_run.addArg("-json");
        const json_output = msdf_run.addOutputFileArg(output_path_json);
        const json_install = b.addInstallBinFile(json_output, output_path_json);
        json_install.step.dependOn(&msdf_run.step);
        b.getInstallStep().dependOn(&json_install.step);

        msdf_run.addArg("-imageout");
        const png_output = msdf_run.addOutputFileArg(output_path_png);
        const png_install = b.addInstallBinFile(png_output, output_path_png);
        png_install.step.dependOn(&msdf_run.step);
        b.getInstallStep().dependOn(&png_install.step);
    }
}

// Sets up shader and asset compilation in the caller project's build graph.
pub fn install(b: *std.Build, d: *std.Build.Dependency, options: Options) void {
    // Add data files to bin
    const install_data_dir = b.addInstallDirectory(.{
        .source_dir = b.path("data"),
        .install_dir = .bin,
        .install_subdir = "data",
    });
    b.getInstallStep().dependOn(&install_data_dir.step);

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
    if (options.render_dynlib) {
        const exe_mod = d.module("exe");
        const lib_path = b.getInstallPath(.lib, ".");
        exe_mod.addRPath(.{ .cwd_relative = lib_path });
    }

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

fn addScript(
    engine_mod: *std.Build.Module,
    render_mod: *std.Build.Module,
    exe_mod: *std.Build.Module,
    script_mod: *std.Build.Module,
) void {
    script_mod.addImport("engine", engine_mod);
    engine_mod.addImport("script", script_mod);
    render_mod.addImport("script", script_mod);
    exe_mod.addImport("script", script_mod);
}

fn compileShader(
    b: *std.Build,
    d: *std.Build.Dependency,
    shader: Shader,
    comptime stage: Shader.Stage,
    comptime config: anytype,
    tag_map: anytype,
) void {
    const arena = b.allocator;
    const input_path = b.pathJoin(&.{ config.shader_dir, shader.file });
    const output_path = b.fmt("{s}.{s}.{s}.spv", .{
        b.pathJoin(&.{ config.data_dir, shader.file }),
        @tagName(stage),
        shader.entrypoint,
    });

    // Create run step
    const shaderc_run = b.addSystemCommand(&.{
        "glslc",
        "-O",
        "-MD",
        "-MF",
    });

    _ = shaderc_run.addDepFileOutputArg("shader.d");
    shaderc_run.addPrefixedDirectoryArg("-I", b.path(config.shader_dir));
    shaderc_run.addPrefixedDirectoryArg("-I", d.path("shader_lib"));

    // Set the stage
    shaderc_run.addArg(b.fmt("-fshader-stage={s}", .{
        @tagName(stage),
    }));

    // Enable the stage and entry point macros
    const STAGE = toUpper(arena, @tagName(stage));
    const ENTRYPOINT = toUpper(arena, shader.entrypoint);
    shaderc_run.addArg(b.fmt("-D{s}", .{STAGE}));
    shaderc_run.addArg(b.fmt("-D{s}", .{ENTRYPOINT}));
    shaderc_run.addArg(b.fmt("-D{s}_{s}", .{ ENTRYPOINT, STAGE }));

    // Add args from conf
    inline for (@typeInfo(@TypeOf(config)).@"struct".fields) |field| {
        const upper = toUpper(arena, field.name);
        switch (@typeInfo(field.type)) {
            .comptime_float, .comptime_int, .float, .int => {
                shaderc_run.addArg(b.fmt("-D{s}={}", .{
                    upper, @field(config, field.name),
                }));
            },
            else => {},
        }
    }

    // Add tag indices
    var tag_iterator = tag_map.iterator();
    var num_tags: u32 = 0;
    while (tag_iterator.next()) |entry| {
        shaderc_run.addArg(b.fmt(
            "-DTAG_{s}={}",
            .{ toUpper(arena, entry.key_ptr.*), entry.value_ptr.* },
        ));
        num_tags += 1;
    }
    shaderc_run.addArg(b.fmt("-DNUM_TAGS={}", .{num_tags}));

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

fn toUpper(arena: std.mem.Allocator, str: []const u8) []const u8 {
    var buffer = arena.alloc(u8, str.len) catch @panic("OOM");
    for (str, 0..) |c, i| {
        buffer[i] = std.ascii.toUpper(c);
    }
    return buffer;
}

fn parseZon(T: type, b: *std.Build, comptime path: []const u8) T {
    var buffer: [1024]u8 = undefined;
    const file = b.build_root.handle.openFile(b.graph.io, path, .{}) catch @panic("Can't open " ++ path);
    defer file.close(b.graph.io);
    var reader = file.reader(b.graph.io, &buffer);
    const data = reader.interface.allocRemainingAlignedSentinel(b.allocator, .unlimited, .of(u8), 0) catch @panic("OOM");
    return std.zon.parse.fromSliceAlloc(T, b.allocator, data, null, .{
        .ignore_unknown_fields = true,
    }) catch @panic("Failed to parse " ++ path);
}
