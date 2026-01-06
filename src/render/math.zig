//! Vector and matrix operations.

const std = @import("std");

/// A 3-component vector.
pub const Vec3 = @Vector(3, f32);

/// Operations on `Vec3`.
pub const vec3 = struct {
    pub const ZERO: Vec3 = @splat(0.0);
    pub const YUP = Vec3{ 0.0, 1.0, 0.0 };

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return @reduce(.Add, a * b);
    }

    pub fn lengthSq(v: Vec3) f32 {
        return dot(v, v);
    }

    pub fn length(v: Vec3) f32 {
        return @sqrt(lengthSq(v));
    }

    pub fn normalize(v: Vec3) Vec3 {
        const len: Vec3 = @splat(length(v));
        return v / len;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return Vec3{
            a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0],
        };
    }
};

/// A 4x4 square matrix.
pub const Mat4 = extern struct {
    /// ## Column-major layout
    /// | `col[0][0]` | `col[1][0]` | `col[2][0]` | `col[3][0]` |
    /// | `col[0][1]` | `col[1][1]` | `col[2][1]` | `col[3][1]` |
    /// | `col[0][2]` | `col[1][2]` | `col[2][2]` | `col[3][2]` |
    /// | `col[0][3]` | `col[1][3]` | `col[2][3]` | `col[3][3]` |
    col: [4][4]f32,

    /// Constructs a perspective projection matrix.
    ///
    /// The matrix transforms vertices from camera space to clip space.
    ///
    /// Camera Space (Right-Handed):
    /// * X is right
    /// * Y is up
    /// * Z is forward (looking out of screen)
    ///
    /// NDC Space:
    /// * X: [-1.0, 1.0]
    /// * Y: [-1.0, 1.0]
    /// * Z: [ 0.0, 1.0]
    pub fn perspective(
        /// The vertical field of view in radians.
        fov: f32,
        /// The width of the viewport divided by the height.
        aspect: f32,
        /// The distance to the near clipping plane (must be > 0).
        near: f32,
        /// The distance to the far clipping plane (must be > nearPlane).
        far: f32,
    ) Mat4 {
        var matrix = std.mem.zeroes(Mat4);

        const yscale = 1.0 / @tan(fov / 2.0);
        const xscale = yscale / aspect;
        const frustum_len = far - near;

        // --- Column 0 ---
        // Scale the X coordinate in camera space
        matrix.col[0][0] = xscale;

        // --- Column 1 ---
        // Scale the Y coordinate in camera space
        matrix.col[1][1] = yscale;

        // --- Column 2 ---
        // Scale the Z coordinate
        matrix.col[2][2] = -far / frustum_len;
        // Perspective divide by Z-distance from the camera
        matrix.col[2][3] = -1.0;

        // --- Column 3 ---
        // Translate the Z coordinate
        matrix.col[3][2] = -(far * near) / frustum_len;

        return matrix;
    }

    /// Constructs a view matrix that looks at a target from a specific position.
    ///
    /// This matrix transforms coordinates from world space to camera space.
    pub fn lookAt(
        /// The position of the camera in world space.
        camera: Vec3,
        /// The point in world space the camera is looking at.
        target: Vec3,
        /// The "up" direction in world space (usually `vec3.YUP`).
        up: Vec3,
    ) Mat4 {
        const z = vec3.normalize(camera - target);
        const x = vec3.normalize(vec3.cross(up, z));
        const y = vec3.normalize(vec3.cross(z, x));

        return .{ .col = .{
            .{ x[0], y[0], z[0], 0.0 }, .{ x[1], y[1], z[1], 0.0 }, .{ x[2], y[2], z[2], 0.0 }, .{
                -vec3.dot(x, camera),
                -vec3.dot(y, camera),
                -vec3.dot(z, camera),
                1.0,
            },
        } };
    }
};

/// Convert degrees to radians.
pub fn radians(degrees: f32) f32 {
    return degrees * (std.math.pi / 180.0);
}
