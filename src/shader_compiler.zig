const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util.zig");
const c = @cImport({
    @cInclude("shaderc/shaderc.h");
});

const log = std.log.scoped(.shader);

const ShaderKind = enum(c_uint) {
    vert = c.shaderc_glsl_vertex_shader,
    frag = c.shaderc_glsl_fragment_shader,
};

pub fn includeResolve(data: ?*const anyopaque, source: [*c]const u8, typ: c_int, in_file: [*c]const u8, depth: usize) callconv(.c) ?*c.shaderc_include_result {
    const alloc: *const Allocator = @ptrCast(@alignCast(data));
    const name = std.mem.span(source);
    log.debug("Include request for {s} in file {s}, type = {}, depth = {}", .{ name, in_file, typ, depth });

    const default_msg = "Include request failed";
    const result = alloc.create(c.shaderc_include_result) catch @panic("OOM");
    result.* = std.mem.zeroInit(c.shaderc_include_result, .{
        .content = default_msg.ptr,
        .content_length = default_msg.len,
        .user_data = @constCast(data),
    });

    _ = blk: {
        const path_raw = util.shaderFilePath(name) catch |err| break :blk err;
        const path = alloc.dupe(u8, path_raw) catch |err| break :blk err;
        // TODO: https://github.com/ziglang/zig/issues/5610
        defer if (result.source_name == null) {
            alloc.free(path);
        };
        const content = util.loadFileZ(alloc.*, path) catch |err| break :blk err;

        result.source_name = path.ptr;
        result.source_name_length = path.len;
        result.content = content.ptr;
        result.content_length = content.len;
    } catch |err| {
        log.err("Include request for {s} failed: {}", .{ name, err });
        return result;
    };

    return result;
}

pub fn includeRelease(data: ?*const anyopaque, result: [*c]c.shaderc_include_result) callconv(.c) void {
    const alloc: *const Allocator = @ptrCast(@alignCast(data));
    if (result.*.source_name) |source_name| {
        const name = source_name[0..result.*.source_name_length];
        alloc.free(name);
        const content = result.*.content[0..result.*.content_length :0];
        alloc.free(content);
    }
    alloc.destroy(@as(*c.shaderc_include_result, result));
}

pub fn compileShader(alloc: Allocator, glsl: []const u8, source_name: [:0]const u8) ![]u8 {
    // Initialize shaderc
    const compiler = c.shaderc_compiler_initialize() orelse return error.ShadercInitialize;
    defer c.shaderc_compiler_release(compiler);
    const options = c.shaderc_compile_options_initialize() orelse return error.ShadercInitialize;
    defer c.shaderc_compile_options_release(options);
    c.shaderc_compile_options_set_optimization_level(options, c.shaderc_optimization_level_size);
    c.shaderc_compile_options_set_source_language(options, c.shaderc_source_language_glsl);
    c.shaderc_compile_options_set_target_env(options, c.shaderc_target_env_vulkan, c.shaderc_env_version_vulkan_1_0);
    c.shaderc_compile_options_set_target_spirv(options, c.shaderc_spirv_version_1_0);
    c.shaderc_compile_options_set_include_callbacks(options, includeResolve, includeRelease, @constCast(&alloc));

    // Determine shader stage/kind from file extension
    const extension = std.fs.path.extension(source_name);
    if (extension.len == 0) return error.NoStageExtension;
    const kind = @intFromEnum(std.meta.stringToEnum(ShaderKind, extension[1..]) orelse return error.NoStageExtension);

    // Compile
    const result = c.shaderc_compile_into_spv(compiler, glsl.ptr, glsl.len, kind, source_name, "main", options);
    defer c.shaderc_result_release(result);

    // Handle and store errors
    if (c.shaderc_result_get_compilation_status(result) != c.shaderc_compilation_status_success) {
        const err = c.shaderc_result_get_error_message(result);
        shader_err.store(err);
        return error.ShaderCompilation;
    }

    // Take output
    const len = c.shaderc_result_get_length(result);
    const bytes = c.shaderc_result_get_bytes(result);
    const spv = try alloc.alloc(u8, len);
    @memcpy(spv, bytes[0..len]);

    return spv;
}

const ErrorStore = struct {
    message_buf: [1024 * 8]u8 = undefined,
    message_len: usize = 0,

    pub fn store(es: *ErrorStore, message: [*c]const u8) void {
        const slice = std.mem.span(message);
        const minlen = @min(slice.len, es.message_buf.len);
        @memcpy(es.message_buf[0..minlen], slice[0..minlen]);
        es.message_len = minlen;
    }

    pub fn load(es: *ErrorStore) []const u8 {
        return es.message_buf[0..es.message_len];
    }
};

pub threadlocal var shader_err: ErrorStore = .{};

// Build-time compiler binary:

const Args = struct {
    output_dir: [:0]const u8,
    input_file: [:0]const u8,

    fn init() !Args {
        var args = std.process.args();
        std.debug.assert(args.skip());

        var output_dir: ?[:0]const u8 = null;
        var input_file: ?[:0]const u8 = null;

        while (args.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "-o")) {
                output_dir = arg[2..];
            }
            input_file = arg;
        }

        return .{
            .output_dir = output_dir orelse {
                log.err("Missing output directory (-o./dir)", .{});
                return error.NoOutputDir;
            },
            .input_file = input_file orelse {
                log.err("Missing input file", .{});
                return error.NoInputFile;
            },
        };
    }
};

fn compileFile(alloc: Allocator, input_path: [:0]const u8, output_path: []const u8) !void {
    const glsl = try util.loadFileZ(alloc, input_path);
    defer alloc.free(glsl);

    const file = try std.fs.cwd().createFile(output_path, .{ .truncate = true });
    defer file.close();

    const spirv = compileShader(alloc, glsl, input_path) catch |err| {
        log.err("{s}", .{shader_err.load()});
        return err;
    };
    defer alloc.free(spirv);

    try file.writeAll(spirv);
}

pub fn main() !void {
    const args = try Args.init();

    // Initialize allocator
    var arena = std.heap.ArenaAllocator.init(std.heap.raw_c_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const basename = std.fs.path.basename(args.input_file);
    const output_file = try std.mem.join(alloc, ".", &.{ basename, "spv" });
    const output_path = try std.fs.path.join(alloc, &.{ args.output_dir, output_file });

    // Invoke shaderc
    try compileFile(alloc, args.input_file, output_path);
}
