const std = @import("std");
const c_abi = @import("c_abi.zig");
const CadBackend = c_abi.CadBackend;
const CadOpType = c_abi.CadOpType;
const CadStatus = c_abi.CadStatus;

pub const Router = struct {
    backends: [@intCast(@intFromEnum(CadOpType.Count))]CadBackend,

    pub fn init() Router {
        var r = Router{
            .backends = undefined,
        };
        // Pure native Zig architecture across all CAD operations
        const count: usize = @intCast(@intFromEnum(CadOpType.Count));
        var i: usize = 0;
        while (i < count) : (i += 1) {
            r.backends[i] = .NativeZig;
        }

        return r;
    }

    pub fn setBackend(self: *Router, op: CadOpType, backend: CadBackend) CadStatus {
        const raw = @intFromEnum(op);
        if (raw < 0 or raw >= @intFromEnum(CadOpType.Count)) {
            return .InvalidArguments;
        }
        const idx: usize = @intCast(raw);
        self.backends[idx] = backend;
        return .Ok;
    }

    pub fn getBackend(self: *const Router, op: CadOpType) CadBackend {
        const raw = @intFromEnum(op);
        if (raw < 0 or raw >= @intFromEnum(CadOpType.Count)) {
            return .Auto;
        }
        const idx: usize = @intCast(raw);
        return self.backends[idx];
    }

    pub fn shouldRouteToOracle(self: *const Router, op: CadOpType) bool {
        return self.getBackend(op) == .COracle;
    }

    pub fn shouldRouteToNative(self: *const Router, op: CadOpType) bool {
        const b = self.getBackend(op);
        return b == .NativeZig or b == .Auto;
    }
};

/// Global Strangler-Fig Router instance:
/// Milestone 4.3 switches BooleanUnion, BooleanDifference, and BooleanIntersection to NativeZig.
pub var global_router: Router = blk: {
    var r = Router.init();
    _ = r.setBackend(.BooleanUnion, .NativeZig);
    _ = r.setBackend(.BooleanDifference, .NativeZig);
    _ = r.setBackend(.BooleanIntersection, .NativeZig);
    break :blk r;
};
