pub const c = @cImport({
    @cDefine("SDL_DISABLE_OLD_NAMES", {});
    @cInclude("SDL3/SDL_gpu.h");
    @cInclude("stb_image.h");
    @cInclude("stb_truetype.h");
});
