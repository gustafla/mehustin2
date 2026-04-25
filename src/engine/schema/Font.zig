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

pub const MsdfJson = struct {
    atlas: Atlas,
    metrics: Metrics,
    glyphs: []const Glyph,
    kerning: []const Kerning,

    pub const Atlas = struct {
        type: Type,
        distanceRange: f32,
        distanceRangeMiddle: f32,
        size: u32,
        width: u32,
        height: u32,
        yOrigin: Origin,
    };

    pub const Metrics = struct {
        emSize: f32,
        lineHeight: f32,
        ascender: f32,
        descender: f32,
        underlineY: f32,
        underlineThickness: f32,
    };

    pub const Kerning = struct {};

    pub const Glyph = struct {
        unicode: u32,
        advance: f32,
        planeBounds: ?Bounds = null,
        atlasBounds: ?Bounds = null,
    };

    pub const Bounds = struct {
        left: f32,
        bottom: f32,
        right: f32,
        top: f32,
    };

    pub const Type = enum { hardmask, softmask, sdf, psdf, msdf, mtsdf };
};
