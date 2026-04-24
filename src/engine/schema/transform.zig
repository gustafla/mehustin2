const std = @import("std");
const StructField = std.builtin.Type.StructField;

pub fn camelCase(buffer: []u8, string: []const u8) []const u8 {
    std.debug.assert(buffer.len >= string.len);
    var i = 0;
    while (i < string.len) : (i += 1) {
        if (string[i] == '_') {
            i += 1;
            buffer[i] = std.ascii.toUpper(string[i]);
        } else buffer[i] = string[i];
    }
    return buffer[0..i];
}

pub fn Jsonify(T: type) type {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var max_name = 0;
            for (info.fields) |f| max_name = @max(max_name, f.name.len);
            var string_buf: [info.fields.len][max_name]u8 = undefined;
            var new_field_names: [info.fields.len][]const u8 = undefined;
            var new_field_types: [info.fields.len]type = undefined;
            var new_field_attributes: [info.fields.len]StructField.Attributes = undefined;
            for (&new_field_types, info.fields) |*new_type, field| {
                new_type.* = Jsonify(field.type);
            }
            for (&string_buf, &new_field_names, info.fields) |*buffer, *new_name, field| {
                new_name.* = camelCase(buffer, field.name);
            }
            for (&new_field_attributes, info.fields) |*new_attr, field| {
                new_attr.* = .{
                    .@"comptime" = field.is_comptime,
                    .@"align" = field.alignment,
                    .default_value_ptr = field.default_value_ptr,
                };
            }
            return @Struct(
                info.layout,
                info.backing_integer,
                &new_field_names,
                &new_field_types,
                &new_field_attributes,
            );
        },
        .@"enum" => []const u8,
        else => return T,
    }
}

pub fn fromJson(T: type, comptime value: Jsonify(T)) T {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var transformed_value: T = undefined;
            for (info.fields) |field| {
                var field_name_buf: [field.name.len]u8 = undefined;
                const camel_name = camelCase(&field_name_buf, field.name);

                // Recursive deep copy
                @field(transformed_value, field.name) =
                    fromJson(field.type, @field(value, camel_name));
            }
            return transformed_value;
        },
        .@"enum" => return std.meta.stringToEnum(T, value) orelse unreachable,
        else => return value,
    }
}
