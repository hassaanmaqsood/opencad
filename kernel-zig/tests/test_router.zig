const std = @import("std");
const testing = std.testing;
const cad = @import("cad_kernel");
const router = cad.RouterMod;
const c_abi = cad;

test "Router: Feature-flag backend switching" {
    var r = router.Router.init();

    // Default primitive box should be NativeZig
    try testing.expectEqual(c_abi.CadBackend.NativeZig, r.getBackend(.PrimitiveBox));

    // Default operations now all route natively to NativeZig
    try testing.expectEqual(c_abi.CadBackend.NativeZig, r.getBackend(.BooleanUnion));

    // Can still dynamically route to COracle if differential comparison is requested
    const status_oracle = r.setBackend(.BooleanUnion, .COracle);
    try testing.expectEqual(c_abi.CadStatus.Ok, status_oracle);
    try testing.expectEqual(c_abi.CadBackend.COracle, r.getBackend(.BooleanUnion));

    // Switch BooleanUnion back to NativeZig
    const status = r.setBackend(.BooleanUnion, .NativeZig);
    try testing.expectEqual(c_abi.CadStatus.Ok, status);
    try testing.expectEqual(c_abi.CadBackend.NativeZig, r.getBackend(.BooleanUnion));

    // Invalid op should be rejected
    const invalid_status = r.setBackend(.Count, .NativeZig);
    try testing.expectEqual(c_abi.CadStatus.InvalidArguments, invalid_status);
}
