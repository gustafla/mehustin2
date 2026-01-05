const std = @import("std");

const c = @import("render.zig").c;

const Error = error{
    FontInitFailed,
    GetGlyphFailed,
    AtlasOverflow,
};

pub const GlyphInfo = struct {
    uv_min: [2]f32,
    uv_max: [2]f32,
    width: f32,
    height: f32,
    x_off: f32,
    y_off: f32,
    advance: f32,
};

pub fn bakeSDFAtlas(
    ttf_data: [*]const u8,
    font_size: f32,
    padding: u32,
    dist_scale: f32,
    width: u32,
    height: u32,
    glyphs: *[128]GlyphInfo,
    atlas: [*]u8,
) Error!void {
    var info: c.stbtt_fontinfo = undefined;
    if (c.stbtt_InitFont(&info, ttf_data, 0) == 0) {
        return Error.FontInitFailed;
    }
    const scale = c.stbtt_ScaleForPixelHeight(&info, font_size);

    @memset(atlas[0 .. width * height], 0);
    @memset(glyphs, std.mem.zeroes(GlyphInfo));

    var x: i32 = 0;
    var y: i32 = 0;
    var max_h: i32 = 0;

    for ('!'..'~' + 1) |glyph| {
        var w: i32 = 0;
        var h: i32 = 0;
        var xoff: i32 = 0;
        var yoff: i32 = 0;

        const sdf_bitmap = c.stbtt_GetCodepointSDF(
            &info,
            scale,
            @intCast(glyph),
            @intCast(padding),
            128,
            dist_scale,
            &w,
            &h,
            &xoff,
            &yoff,
        ) orelse return Error.GetGlyphFailed;
        defer c.stbtt_FreeSDF(sdf_bitmap, null);

        // Advance row
        if (x + w >= width) {
            x = 0;
            y += max_h;
            max_h = 0;
        }

        // Bounds check remaining space
        if (y + h >= height or x + w >= width) {
            return Error.AtlasOverflow;
        }

        // Blit glyph to atlas
        var row: i32 = 0;
        while (row < h) : (row += 1) {
            const wu: usize = @intCast(w);
            const src_start: usize = @intCast(row * w);
            const dst_start: usize = @intCast((y + row) * @as(i32, @intCast(width)) + x);
            @memcpy(atlas[dst_start .. dst_start + wu], sdf_bitmap[src_start .. src_start + wu]);
        }

        var advanceWidth: i32 = 0;
        var leftSide: i32 = 0;
        c.stbtt_GetCodepointHMetrics(&info, @intCast(glyph), &advanceWidth, &leftSide);
        glyphs[glyph] = .{
            .uv_min = .{
                @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width)),
                @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height)),
            },
            .uv_max = .{
                @as(f32, @floatFromInt(x + w)) / @as(f32, @floatFromInt(width)),
                @as(f32, @floatFromInt(y + h)) / @as(f32, @floatFromInt(height)),
            },
            .width = @floatFromInt(w),
            .height = @floatFromInt(h),
            .x_off = @floatFromInt(xoff),
            .y_off = @floatFromInt(yoff),
            .advance = @as(f32, @floatFromInt(advanceWidth)) * scale,
        };

        if (h > max_h) {
            max_h = h;
        }

        x += w;
    }
}
