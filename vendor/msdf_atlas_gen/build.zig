const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe_mod = b.addModule("msdf_atlas_gen", .{
        .target = b.resolveTargetQuery(.{}), // Native
        .link_libcpp = true,
    });
    const exe = b.addExecutable(.{
        .name = "msdf-atlas-gen",
        .root_module = exe_mod,
    });

    // Define C Macros
    exe_mod.addCMacro("MSDF_ATLAS_STANDALONE", "");
    exe_mod.addCMacro("MSDF_ATLAS_NO_ARTERY_FONT", "");

    // Resolve dependencies from build.zig.zon
    const msdf_atlas_gen_dep = b.dependency("msdf_atlas_gen", .{});
    const msdfgen_dep = b.dependency("msdfgen", .{});

    // Set include directories
    exe_mod.addIncludePath(msdf_atlas_gen_dep.path("."));
    exe_mod.addIncludePath(msdf_atlas_gen_dep.path("msdf-atlas-gen"));
    exe_mod.addIncludePath(msdfgen_dep.path("."));

    // Link dependencies
    exe_mod.linkSystemLibrary("freetype2", .{});
    exe_mod.linkSystemLibrary("png", .{});
    exe_mod.linkSystemLibrary("z", .{});
    exe_mod.linkSystemLibrary("pthread", .{});

    const cxx_flags = &[_][]const u8{
        "-std=c++11",
    };

    // msdf-atlas-gen sources
    exe_mod.addCSourceFiles(.{
        .root = msdf_atlas_gen_dep.path("msdf-atlas-gen"),
        .files = &.{
            // "artery-font-export.cpp",
            "bitmap-blit.cpp",
            "Charset.cpp",
            "charset-parser.cpp",
            "csv-export.cpp",
            "FontGeometry.cpp",
            "glyph-generators.cpp",
            "GlyphGeometry.cpp",
            "GridAtlasPacker.cpp",
            "image-encode.cpp",
            "json-export.cpp",
            // "main.cpp",
            "Padding.cpp",
            "RectanglePacker.cpp",
            "shadron-preview-generator.cpp",
            "size-selectors.cpp",
            "TightAtlasPacker.cpp",
            "utf8.cpp",
            "Workload.cpp",
        },
        .flags = cxx_flags,
    });

    // msdfgen core sources
    exe_mod.addCSourceFiles(.{
        .root = msdfgen_dep.path("core"),
        .files = &.{
            "contour-combiners.cpp",
            "Contour.cpp",
            "convergent-curve-ordering.cpp",
            "DistanceMapping.cpp",
            "edge-coloring.cpp",
            "EdgeHolder.cpp",
            "edge-segments.cpp",
            "edge-selectors.cpp",
            "equation-solver.cpp",
            "export-svg.cpp",
            "msdf-error-correction.cpp",
            "MSDFErrorCorrection.cpp",
            "msdfgen.cpp",
            "Projection.cpp",
            "rasterization.cpp",
            "render-sdf.cpp",
            "save-bmp.cpp",
            "save-fl32.cpp",
            "save-rgba.cpp",
            "save-tiff.cpp",
            "Scanline.cpp",
            "sdf-error-estimation.cpp",
            "Shape.cpp",
            "shape-description.cpp",
        },
        .flags = cxx_flags,
    });

    // msdfgen ext sources
    exe_mod.addCSourceFiles(.{
        .root = msdfgen_dep.path("ext"),
        .files = &.{
            "import-font.cpp",
            "import-svg.cpp",
            "resolve-shape-geometry.cpp",
            "save-png.cpp",
        },
        .flags = cxx_flags,
    });

    // Add patched main
    exe_mod.addCSourceFile(.{
        .file = b.path("src/main.cpp"),
        .flags = cxx_flags,
    });

    // Config header
    const msdfgen_config = b.addConfigHeader(.{
        .style = .blank,
        .include_path = "msdfgen/msdfgen-config.h",
    }, .{
        .MSDFGEN_USE_OPENMP = 1,
        .MSDFGEN_DISABLE_SVG = 1,
        .MSDFGEN_USE_LIBPNG = 1,
        .MSDFGEN_USE_CPP11 = 1,
        .MSDFGEN_VERSION = "\"1.13\"",
    });
    exe_mod.addConfigHeader(msdfgen_config);

    b.installArtifact(exe);
}
