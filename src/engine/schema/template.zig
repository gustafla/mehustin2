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
        const template = for (templates) |template| {
            if (std.mem.eql(u8, template.name, self.template)) {
                break template;
            }
        } else @panic("No template found!");

        var unrolled: std.ArrayList(Pass) = .empty;
        defer unrolled.deinit(allocator);
        for (self.args) |args| {
            const passes = try unrolled.addManyAsSlice(allocator, template.passes.len);
            // Seed the unrolling with top-level template data. Slices point to template.
            @memcpy(passes, template.passes);
            // Allocate fresh memory for each pass unrolled.
            for (passes) |*pass| try deepDupe(allocator, Pass, pass);
            // Replace strings matching params with given args.
            for (passes) |*pass| apply(Pass, pass, template.params, args);
        }
        return unrolled.toOwnedSlice(allocator);
    }
};

fn deepDupe(
    allocator: Allocator,
    T: type,
    ptr: *T,
) Allocator.Error!void {
    switch (@typeInfo(T)) {
        .@"struct" => |sinfo| inline for (sinfo.fields) |field| {
            try deepDupe(
                allocator,
                field.type,
                &@field(ptr.*, field.name),
            );
        },
        .@"union" => switch (ptr.*) {
            inline else => |*inner| try deepDupe(
                allocator,
                @TypeOf(inner.*),
                inner,
            ),
        },
        .pointer => |pinfo| {
            if (pinfo.size != .slice) @compileError("Pointers aren't supported");

            // Ignore strings. Strings will be substituted.
            if (pinfo.child == u8) return;

            const slice_dupe = try allocator.dupe(pinfo.child, ptr.*);
            for (slice_dupe) |*item| {
                try deepDupe(allocator, pinfo.child, item);
            }
            ptr.* = slice_dupe;
        },
        else => {},
    }
}

fn apply(
    T: type,
    ptr: *T,
    params: []const []const u8,
    args: []const []const u8,
) void {
    switch (@typeInfo(T)) {
        .@"struct" => |sinfo| inline for (sinfo.fields) |field| {
            apply(field.type, &@field(ptr.*, field.name), params, args);
        },
        .@"union" => switch (ptr.*) {
            inline else => |*inner| apply(@TypeOf(inner.*), inner, params, args),
        },
        .pointer => |pinfo| {
            if (pinfo.size != .slice) @compileError("Pointers aren't supported");

            if (pinfo.child == u8) {
                // Check if string is param, and substitute with arg if so.
                for (params, args) |param, arg| {
                    if (std.mem.eql(u8, ptr.*, param)) {
                        ptr.* = arg;
                        return;
                    }
                }
            } else {
                for (ptr.*) |*item| {
                    apply(pinfo.child, @constCast(item), params, args);
                }
            }
        },
        else => {},
    }
}
