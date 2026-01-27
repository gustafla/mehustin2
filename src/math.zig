//! Vector, matrix and quaternion operations.

const std = @import("std");

/// A 3-component vector.
pub const Vec3 = @Vector(3, f32);

/// Operations on `Vec3`.
pub const vec3 = struct {
    pub const YUP: Vec3 = .{ 0.0, 1.0, 0.0 };

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

    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        const t_vec: Vec3 = @splat(t);
        return a + (b - a) * t_vec;
    }

    /// Rotates vector v around normalized axis k by angle (radians).
    /// Assumes v is perpendicular to k (v . k = 0).
    pub fn rotatePerpendicular(v: Vec3, k: Vec3, angle: f32) Vec3 {
        const cos_v: Vec3 = @splat(std.math.cos(angle));
        const sin_v: Vec3 = @splat(std.math.sin(angle));

        const tangent = vec3.cross(k, v);
        return (v * cos_v) + (tangent * sin_v);
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

    /// Computes the result of `self * other`.
    pub fn mmul(self: Mat4, other: Mat4) Mat4 {
        var result: Mat4 = undefined;

        // Iterate over the columns of the 'other' matrix
        inline for (0..4) |i| {
            // We use @Vector to enable SIMD instructions.
            // Zig arrays [4]f32 coerce implicitly to @Vector(4, f32)
            var acc: @Vector(4, f32) = @splat(0.0);

            inline for (0..4) |k| {
                // column k of self * scalar k of other's column i
                const self_col: @Vector(4, f32) = self.col[k];
                const scalar: @Vector(4, f32) = @splat(other.col[i][k]);

                // Fused multiply-add if hardware supports it
                acc = @mulAdd(@Vector(4, f32), self_col, scalar, acc);
            }

            result.col[i] = acc;
        }

        return result;
    }

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

/// A 4-component vector representing a rotation (x, y, z, w).
pub const Quat = @Vector(4, f32);

/// Operations on `Quat`.
pub const quat = struct {
    /// The identity quaternion (no rotation).
    pub const IDENTITY = Quat{ 0.0, 0.0, 0.0, 1.0 };

    /// Creates a rotation from an axis and an angle (in radians).
    ///
    /// The axis must be normalized.
    pub fn fromAxisAngle(axis: Vec3, angle: f32) Quat {
        const half_angle = angle * 0.5;
        const s = @sin(half_angle);
        const c = @cos(half_angle);

        return Quat{
            axis[0] * s,
            axis[1] * s,
            axis[2] * s,
            c,
        };
    }

    /// Normalizes the quaternion.
    ///
    /// Rotations must always be unit length.
    pub fn normalize(q: Quat) Quat {
        const dot = @reduce(.Add, q * q);
        return q / @as(Quat, @splat(@sqrt(dot)));
    }

    /// Combines two rotations (equivalent to `lhs * rhs`).
    ///
    /// The result represents the rotation of `rhs` followed by `lhs`.
    pub fn mul(lhs: Quat, rhs: Quat) Quat {
        const q1x = lhs[0];
        const q1y = lhs[1];
        const q1z = lhs[2];
        const q1w = lhs[3];
        const q2x = rhs[0];
        const q2y = rhs[1];
        const q2z = rhs[2];
        const q2w = rhs[3];

        return Quat{
            q1w * q2x + q1x * q2w + q1y * q2z - q1z * q2y,
            q1w * q2y - q1x * q2z + q1y * q2w + q1z * q2x,
            q1w * q2z + q1x * q2y - q1y * q2x + q1z * q2w,
            q1w * q2w - q1x * q2x - q1y * q2y - q1z * q2z,
        };
    }
};

/// Convert degrees to radians.
pub fn radians(degrees: f32) f32 {
    return degrees * (std.math.pi / 180.0);
}
