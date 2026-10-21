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
        const count: usize = @intCast(@intFromEnum(CadOpType.Count));
        var i: usize = 0;
        while (i < count) : (i += 1) {
            r.backends[i] = .NativeZig;
        }
        r.backends[@intCast(@intFromEnum(CadOpType.BooleanUnion))] = .COracle;
        r.backends[@intCast(@intFromEnum(CadOpType.BooleanDifference))] = .COracle;
        r.backends[@intCast(@intFromEnum(CadOpType.BooleanIntersection))] = .COracle;
        r.backends[@intCast(@intFromEnum(CadOpType.Fillet))] = .COracle;
        r.backends[@intCast(@intFromEnum(CadOpType.Chamfer))] = .COracle;
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

pub var global_router: Router = Router.init();

