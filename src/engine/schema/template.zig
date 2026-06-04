const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn Template(Pass: type) type {
    return struct {
        name: []const u8,
        params: []const []const u8,
        passes: []const Pass,
    };
}

pub const Unroll = struct {
    template: []const u8,
    args: []const []const []const u8,

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
    params: []const []const u8,
    args: []const []const u8,
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
        .pointer => |pinfo| {
            if (pinfo.size != .slice) @compileError("Pointers aren't supported");

            if (pinfo.child == u8) {
                // Check if string is param, and substitute with arg if so.
                for (params, args) |param, arg| {
                    if (std.mem.eql(u8, val, param)) return arg;
                }
                return val;
            } else {
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
        params: []const []const u8,
        args: []const []const u8,
    ) Allocator.Error![]const T {
        const new_slice = try self.allocator.alloc(T, slice.len);
        for (new_slice, slice) |*new_item, item| {
            new_item.* = try applySubstitution(self, item, params, args);
        }
        return new_slice;
    }
};

pub const SliceAllocatorComptime = struct {
    pub fn allocApply(
        T: type,
        comptime slice: []const T,
        comptime params: []const []const u8,
        comptime args: []const []const u8,
    ) ![]const T {
        var new_array: [slice.len]T = undefined;
        for (&new_array, slice) |*new_item, item| {
            new_item.* = try applySubstitution(@This(), item, params, args);
        }

        const final_array = new_array;
        return &final_array;
    }
};
