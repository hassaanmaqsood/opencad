const std = @import("std");
const Vec3 = @import("../math/vec3.zig").Vec3;

/// 3D Unit Quaternion representation for rigid-body rotation
pub const Quaternion = struct {
    w: f64,
    x: f64,
    y: f64,
    z: f64,

    pub const identity = Quaternion{ .w = 1.0, .x = 0.0, .y = 0.0, .z = 0.0 };

    pub fn init(w: f64, x: f64, y: f64, z: f64) Quaternion {
        const q = Quaternion{ .w = w, .x = x, .y = y, .z = z };
        return q.normalize();
    }

    pub fn fromAxisAngle(axis: Vec3, angle_rad: f64) Quaternion {
        const a_len = axis.norm();
        if (a_len < 1e-12) return identity;
        const half_a = angle_rad * 0.5;
        const sin_half = @sin(half_a);
        const inv_len = 1.0 / a_len;
        return (Quaternion{
            .w = @cos(half_a),
            .x = @as(f64, @floatCast(axis.x)) * inv_len * sin_half,
            .y = @as(f64, @floatCast(axis.y)) * inv_len * sin_half,
            .z = @as(f64, @floatCast(axis.z)) * inv_len * sin_half,
        }).normalize();
    }

    pub fn norm(self: Quaternion) f64 {
        return @sqrt(self.w * self.w + self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fn normalize(self: Quaternion) Quaternion {
        const n = self.norm();
        if (n < 1e-12) return identity;
        const inv = 1.0 / n;
        return .{
            .w = self.w * inv,
            .x = self.x * inv,
            .y = self.y * inv,
            .z = self.z * inv,
        };
    }

    pub fn mul(self: Quaternion, o: Quaternion) Quaternion {
        const q = Quaternion{
            .w = self.w * o.w - self.x * o.x - self.y * o.y - self.z * o.z,
            .x = self.w * o.x + self.x * o.w + self.y * o.z - self.z * o.y,
            .y = self.w * o.y - self.x * o.z + self.y * o.w + self.z * o.x,
            .z = self.w * o.z + self.x * o.y - self.y * o.x + self.z * o.w,
        };
        return q.normalize();
    }

    pub fn rotate(self: Quaternion, p: Vec3) Vec3 {
        // v' = q * v * q^-1
        const px = @as(f64, @floatCast(p.x));
        const py = @as(f64, @floatCast(p.y));
        const pz = @as(f64, @floatCast(p.z));

        const qv = Quaternion{ .w = 0.0, .x = px, .y = py, .z = pz };
        const q_inv = Quaternion{ .w = self.w, .x = -self.x, .y = -self.y, .z = -self.z };
        const res = self.mul(qv).mul(q_inv);

        return Vec3.init(
            @as(f32, @floatCast(res.x)),
            @as(f32, @floatCast(res.y)),
            @as(f32, @floatCast(res.z)),
        );
    }
};

/// Special Euclidean Group SE(3) rigid-body transformation (Rotation + Translation)
pub const SE3 = struct {
    rotation: Quaternion,
    translation: Vec3,

    pub const identity = SE3{
        .rotation = Quaternion.identity,
        .translation = Vec3.init(0, 0, 0),
    };

    pub fn init(rotation: Quaternion, translation: Vec3) SE3 {
        return .{
            .rotation = rotation.normalize(),
            .translation = translation,
        };
    }

    pub fn fromTransform4x4(m: [16]f32) SE3 {
        // Column-major 4x4 matrix
        const r00 = @as(f64, m[0]);
        const r10 = @as(f64, m[1]);
        const r20 = @as(f64, m[2]);
        const r01 = @as(f64, m[4]);
        const r11 = @as(f64, m[5]);
        const r21 = @as(f64, m[6]);
        const r02 = @as(f64, m[8]);
        const r12 = @as(f64, m[9]);
        const r22 = @as(f64, m[10]);

        const tr = r00 + r11 + r22;
        var q = Quaternion.identity;

        if (tr > 0.0) {
            const s = @sqrt(tr + 1.0) * 2.0;
            q.w = 0.25 * s;
            q.x = (r21 - r12) / s;
            q.y = (r02 - r20) / s;
            q.z = (r10 - r01) / s;
        } else if (r00 > r11 and r00 > r22) {
            const s = @sqrt(1.0 + r00 - r11 - r22) * 2.0;
            q.w = (r21 - r12) / s;
            q.x = 0.25 * s;
            q.y = (r01 + r10) / s;
            q.z = (r02 + r20) / s;
        } else if (r11 > r22) {
            const s = @sqrt(1.0 + r11 - r00 - r22) * 2.0;
            q.w = (r02 - r20) / s;
            q.x = (r01 + r10) / s;
            q.y = 0.25 * s;
            q.z = (r12 + r21) / s;
        } else {
            const s = @sqrt(1.0 + r22 - r00 - r11) * 2.0;
            q.w = (r10 - r01) / s;
            q.x = (r02 + r20) / s;
            q.y = (r12 + r21) / s;
            q.z = 0.25 * s;
        }

        const t = Vec3.init(m[12], m[13], m[14]);
        return SE3.init(q, t);
    }

    pub fn toColumnMajor4x4(self: SE3) [16]f32 {
        const q = self.rotation;
        const x2 = q.x + q.x;
        const y2 = q.y + q.y;
        const z2 = q.z + q.z;
        const xx = q.x * x2;
        const xy = q.x * y2;
        const xz = q.x * z2;
        const yy = q.y * y2;
        const yz = q.y * z2;
        const zz = q.z * z2;
        const wx = q.w * x2;
        const wy = q.w * y2;
        const wz = q.w * z2;

        return [16]f32{
            // Col 0
            @as(f32, @floatCast(1.0 - (yy + zz))),
            @as(f32, @floatCast(xy + wz)),
            @as(f32, @floatCast(xz - wy)),
            0.0,
            // Col 1
            @as(f32, @floatCast(xy - wz)),
            @as(f32, @floatCast(1.0 - (xx + zz))),
            @as(f32, @floatCast(yz + wx)),
            0.0,
            // Col 2
            @as(f32, @floatCast(xz + wy)),
            @as(f32, @floatCast(yz - wx)),
            @as(f32, @floatCast(1.0 - (xx + yy))),
            0.0,
            // Col 3 (Translation)
            self.translation.x,
            self.translation.y,
            self.translation.z,
            1.0,
        };
    }

    pub fn transformPoint(self: SE3, p: Vec3) Vec3 {
        return self.rotation.rotate(p).add(self.translation);
    }

    pub fn transformDirection(self: SE3, d: Vec3) Vec3 {
        return self.rotation.rotate(d);
    }

    /// Retract 6D twist (omega, v) via Lie exponential map
    pub fn retract(self: SE3, omega: [3]f64, v: [3]f64) SE3 {
        const theta_sq = omega[0] * omega[0] + omega[1] * omega[1] + omega[2] * omega[2];
        const theta = @sqrt(theta_sq);

        var dq = Quaternion.identity;
        if (theta > 1e-12) {
            const half_t = theta * 0.5;
            const s = @sin(half_t) / theta;
            dq = (Quaternion{
                .w = @cos(half_t),
                .x = omega[0] * s,
                .y = omega[1] * s,
                .z = omega[2] * s,
            }).normalize();
        }

        const new_rot = dq.mul(self.rotation);
        const dt = Vec3.init(
            @as(f32, @floatCast(v[0])),
            @as(f32, @floatCast(v[1])),
            @as(f32, @floatCast(v[2])),
        );
        const new_trans = self.translation.add(dt);

        return SE3.init(new_rot, new_trans);
    }
};
