pub const options = @import("options");

pub const camera = @import("engine/camera.zig");
pub const font = @import("engine/font.zig");
pub const math = @import("engine/math.zig");
pub const noise = @import("engine/noise.zig");
pub const resource = @import("engine/resource.zig");
pub const schema = @import("engine/schema.zig");
pub const timeline = @import("engine/timeline.zig");
pub const types = @import("engine/types.zig");
pub const udp = @import("engine/udp.zig");
pub const util = @import("engine/util.zig");

pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL_gpu.h");
    @cInclude("SDL3/SDL_timer.h");
    @cInclude("stb_image.h");
    @cInclude("stb_truetype.h");
    @cInclude("par_shapes.h");
});
