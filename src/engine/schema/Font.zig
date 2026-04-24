file: []const u8,
variables: []const []const u8 = &.{},
size: f32,
padding_em: f32,

pub const Origin = enum {
    left,
    right,
    top,
    bottom,
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    center,
};

pub const Atlas = struct {
    atlas: Parameters,
    metrics: Metrics,
    glyphs: []const Glyph,
    kerning: []const Kerning,

    pub const Parameters = struct {
        type: Type,
        distance_range: f32,
        distance_range_middle: f32,
        size: u32,
        width: u32,
        height: u32,
        y_origin: Origin,
    };

    pub const Metrics = struct {
        em_size: f32,
        line_height: f32,
        ascender: f32,
        descender: f32,
        underline_y: f32,
        underline_thickness: f32,
    };

    pub const Kerning = struct {};

    pub const Glyph = struct {
        unicode: u32,
        advance: f32,
        plane_bounds: ?Bounds,
        atlas_bounds: ?Bounds,
    };

    pub const Bounds = struct {
        left: f32,
        bottom: f32,
        right: f32,
        top: f32,
    };

    pub const Type = enum { hardmask, softmask, sdf, psdf, msdf, mtsdf };
};
