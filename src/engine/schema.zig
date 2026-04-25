const std = @import("std");

const script = @import("script");

const camera = @import("camera.zig");
const math = @import("math.zig");
pub const Font = @import("schema/Font.zig");
pub const Shader = @import("schema/Shader.zig");
const timeline = @import("timeline.zig");
const types = @import("types.zig");
const PrimitiveType = types.PrimitiveType;
const RasterizerState = types.RasterizerState;
const CompareOp = types.CompareOp;
const BlendState = types.BlendState;
const LoadOp = types.LoadOp;
const StoreOp = types.StoreOp;
const Filter = types.Filter;
const SamplerMipmapMode = types.SamplerMipmapMode;
const SamplerAddressMode = types.SamplerAddressMode;
const TextureFormat = types.TextureFormat;
const SampleCount = types.SampleCount;

pub const Render = struct {
    color_targets: []const TargetTexture = &.{},
    depth_targets: []const TargetTexture = &.{},
    samplers: []const Sampler,
    passes: []const Pass,

    pub const GraphicsPipeline = struct {
        shader: Shader.Graphics,
        primitive_type: PrimitiveType = .trianglelist,
        rasterizer_state: RasterizerState = .{},
        enable_alpha_to_coverage: bool = false,
        depth_test: ?struct { // TODO: Consider implementing full DepthStencilState
            compare_op: CompareOp = .less_or_equal,
            enable: bool = true,
            write: bool = true,
        } = null,
        blend_states: []const BlendState = &.{},
    };

    pub const ColorTarget = union(enum) {
        index: usize,
        swapchain,
    };

    pub fn RenderTarget(T: type) type {
        return struct {
            target: T,
            resolve_target: ?T = null,
            load_op: LoadOp = .clear,
            store_op: StoreOp = .store,
        };
    }

    pub const Sampler = struct {
        name: []const u8,
        min_filter: Filter = .nearest,
        mag_filter: Filter = .nearest,
        mipmap_mode: SamplerMipmapMode = .nearest,
        address_mode_u: SamplerAddressMode = .mirrored_repeat,
        address_mode_v: SamplerAddressMode = .mirrored_repeat,
        address_mode_w: SamplerAddressMode = .clamp_to_edge,
        mip_lod_bias: f32 = 0,
        max_anisotropy: f32 = 0,
        compare_op: CompareOp = .less_or_equal,
        min_lod: f32 = 0,
        max_lod: f32 = 1024,
        enable_anisotropy: bool = false,
        enable_compare: bool = false,
    };

    pub const TextureSamplerBinding = struct {
        texture: []const u8,
        sampler: []const u8,
    };

    pub const Drawcall = struct {
        require_all_tags: []const timeline.Tag = &.{},
        require_any_tags: []const timeline.Tag = &.{},
        pipelines: []const GraphicsPipeline,
        index_buffer: ?[]const u8 = null,
        vertex_buffer: ?[]const u8 = null,
        instance_buffer: ?[]const u8 = null,
        vertex_samplers: []const TextureSamplerBinding = &.{},
        fragment_samplers: []const TextureSamplerBinding = &.{},
        vertex_storage_buffers: []const []const u8 = &.{},
        fragment_storage_buffers: []const []const u8 = &.{},
        num_vertices: ?u32 = null,
        num_instances: ?u32 = null,
    };

    pub const ComputeDimensions = struct {
        x: u32,
        y: u32 = 1,
        z: u32 = 1,
    };

    pub const ComputeDispatch = struct {
        require_all_tags: []const timeline.Tag = &.{},
        require_any_tags: []const timeline.Tag = &.{},
        comp: Shader,
        threadcount: ComputeDimensions,
        groupcount: ComputeDimensions,
        samplers: []const TextureSamplerBinding = &.{},
        readonly_storage_textures: []const []const u8 = &.{},
        readonly_storage_buffers: []const []const u8 = &.{},
    };

    pub const Pass = union(enum) {
        render: RenderPass,
        compute: ComputePass,
    };

    pub const RenderPass = struct {
        require_all_tags: []const timeline.Tag = &.{},
        require_any_tags: []const timeline.Tag = &.{},
        drawcalls: []const Drawcall,
        color_targets: []const RenderTarget(ColorTarget) = &.{.{ .target = .swapchain }},
        depth_target: ?RenderTarget(usize) = null,
    };

    pub const ComputePass = struct {
        require_all_tags: []const timeline.Tag = &.{},
        require_any_tags: []const timeline.Tag = &.{},
        dispatches: []const ComputeDispatch,
        readwrite_storage_textures: []const []const u8 = &.{},
        readwrite_storage_buffers: []const []const u8 = &.{},
    };

    pub const TargetTexture = struct {
        format: TextureFormat,
        p: u32 = 1,
        q: u32 = 1,
        sample_count: SampleCount = .@"1",
    };
};

pub const Timeline = struct {
    tags: []const Tag,
    camera: Camera,
    text: Text,

    pub const Tag = struct {
        name: []const u8,
        duration: f32,
        t: Time,

        pub const Time = union(enum) {
            abs: f32,
            rel: struct {
                to: enum { start, end } = .start,
                of: []const u8,
                by: f32 = 0,
            },
            seq,
        };
    };

    pub const EventTime = union(enum) {
        abs: f32,
        rel: struct { tag: []const u8, by: f32 = 0 },
    };

    pub const Camera = struct {
        control: []const Control,
        tracks: []const []const Segment,
        effects: []const Effect,

        pub const Control = struct {
            t: EventTime,
            i: u32,
            position_lock: ?script.Anchor = null,
            target_lock: ?script.Anchor = null,
            blend: f32 = 0,
        };

        pub const Segment = struct {
            t: EventTime,
            motion: []const camera.Motion = &.{},
            entry: ?camera.State = null,
            blend: f32 = 1,
        };

        pub const Effect = struct {
            t: EventTime = .{ .abs = 0 },
            duration: f32 = std.math.inf(f32),
            motion: camera.Motion,
            fade_in: f32 = 1,
            fade_out: f32 = 1,
        };
    };

    pub const Text = struct {
        fonts: []const Font,
        track: []const Segment,

        pub const Segment = struct {
            t: EventTime = .{ .abs = 0 },
            duration: f32 = std.math.inf(f32),
            text: union(enum) {
                str: []const u8, // Inline string
                ref: script.String, // script.zig reflection
            },
            font: usize = 0,
            pos: math.Vec2, // NDC position
            scale: f32 = 0.1, // Fraction of screen height
            origin: Font.Origin = .top_left,
            color: math.Vec4 = @splat(1),
            effect: enum(u8) {
                none,
                uv_ripple,
            } = .none,
            anim: ?union(enum) {
                fade: math.Vec4, // Fade from a color value
                slide: math.Vec2, // Slide from an NDC position
                typewriter, // Reveal text letter by letter
            } = null,
            fade_in: f32 = 0,
            fade_out: f32 = 0,
        };
    };
};
