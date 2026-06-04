const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Param = struct {
    name: []const u8,
    default: ?[]const u8 = null,
};

pub fn Template(Pass: type) type {
    return struct {
        name: []const u8,
        params: []const Param,
        passes: []const Pass,
    };
}

pub const Unroll = struct {
    template: []const u8,
    args: []const []const ?[]const u8,

    pub fn unrollAlloc(
        self: Unroll,
        allocator: Allocator,
        Pass: type,
        templates: []const Template(Pass),
    ) Allocator.Error![]const Pass {
        const template = get(Pass, templates, self.template);

        const slice_alloc: SliceAllocator = .init(allocator);
        var unrolled: std.ArrayList(Pass) = .empty;
        defer unrolled.deinit(allocator);

        for (self.args) |args| {
            const passes = try unrolled.addManyAsSlice(allocator, template.passes.len);
            for (passes, template.passes) |*pass, template_pass| {
                pass.* = try applySubstitution(slice_alloc, template_pass, template.params, args);
            }
        }

        return unrolled.toOwnedSlice(allocator);
    }
};

pub fn get(
    Pass: type,
    templates: []const Template(Pass),
    name: []const u8,
) Template(Pass) {
    for (templates) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    if (@inComptime()) {
        @compileError("Template not found: " ++ name);
    } else {
        std.log.err("Template not found: {s}", .{name});
        @panic("Unresolved template reference");
    }
}

pub fn applySubstitution(
    slice_alloc: anytype,
    val: anytype,
    params: []const Param,
    args: []const ?[]const u8,
) !@TypeOf(val) {
    switch (@typeInfo(@TypeOf(val))) {
        .@"struct" => |sinfo| {
            var new_val: @TypeOf(val) = undefined;
            inline for (sinfo.fields) |field| {
                @field(new_val, field.name) = try applySubstitution(
                    slice_alloc,
                    @field(val, field.name),
                    params,
                    args,
                );
            }
            return new_val;
        },
        .@"union" => {
            return switch (val) {
                inline else => |inner, tag| @unionInit(
                    @TypeOf(val),
                    @tagName(tag),
                    try applySubstitution(slice_alloc, inner, params, args),
                ),
            };
        },
        .optional => |oinfo| {
            if (val) |v| {
                // Optional strings are allowed to resolve to null
                if (oinfo.child == []const u8) {
                    return resolveParam(v, params, args);
                }
                return try applySubstitution(slice_alloc, v, params, args);
            }
            return null;
        },
        .pointer => |pinfo| {
            if (pinfo.size != .slice) @compileError("Pointers aren't supported");

            if (pinfo.child == u8) {
                // Single string field
                return resolveParam(val, params, args) orelse if (@inComptime()) {
                    @compileError("No match for argument:" ++ val);
                } else {
                    std.log.err("No match for argument: {s}", .{val});
                    @panic("Unresolved template argument");
                };
            } else {
                // Delegate slice building to allocators
                return try slice_alloc.allocApply(pinfo.child, val, params, args);
            }
        },
        else => return val,
    }
}

pub const SliceAllocator = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) SliceAllocator {
        return .{ .allocator = allocator };
    }

    pub fn allocApply(
        self: *const SliceAllocator,
        T: type,
        slice: []const T,
        params: []const Param,
        args: []const ?[]const u8,
    ) Allocator.Error![]const T {
        var list: std.ArrayList(T) = .empty;
        errdefer list.deinit(self.allocator);

        for (slice) |item| {
            if (T == []const u8) {
                // Null argument elision
                if (resolveParam(item, params, args)) |resolved| {
                    try list.append(self.allocator, resolved);
                }
            } else {
                try list.append(
                    self.allocator,
                    try applySubstitution(self, item, params, args),
                );
            }
        }

        return list.toOwnedSlice(self.allocator);
    }
};

pub const SliceAllocatorComptime = struct {
    pub fn allocApply(
        T: type,
        comptime slice: []const T,
        comptime params: []const Param,
        comptime args: []const ?[]const u8,
    ) ![]const T {
        var new_array: [slice.len]T = undefined;
        var i = 0;

        for (slice) |item| {
            if (T == []const u8) {
                // Null argument elision
                if (resolveParam(item, params, args)) |resolved| {
                    new_array[i] = resolved;
                    i += 1;
                }
            } else {
                new_array[i] = try applySubstitution(@This(), item, params, args);
                i += 1;
            }
        }

        const final_array = new_array[0..i].*;
        return &final_array;
    }
};

fn resolveParam(
    str: []const u8,
    params: []const Param,
    args: []const ?[]const u8,
) ?[]const u8 {
    for (params, 0..) |param, i| {
        if (std.mem.eql(u8, str, param.name)) {
            // A matching positional argument is the first priority.
            if (i < args.len) if (args[i]) |arg| return arg;

            // Second, recursively resolve the parameter's default.
            // This either yields the default string itself,
            // or a value from some other positional argument,
            // or null if both a matching argument and its default are null.
            if (param.default) |default| return resolveParam(default, params, args);

            // No arg, no default.
            return null;
        }
    }
    return str;
}
