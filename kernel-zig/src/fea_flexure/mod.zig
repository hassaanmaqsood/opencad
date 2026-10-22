pub const mesh = @import("mesh.zig");
pub const solver = @import("solver.zig");
pub const compliance = @import("compliance.zig");
pub const flexure = @import("flexure.zig");
pub const wasm = @import("wasm.zig");

pub const TetMesh = mesh.TetMesh;
pub const ElementType = mesh.ElementType;
pub const FeaSolver = solver.FeaSolver;
pub const MaterialProps = solver.MaterialProps;
pub const ComplianceMatrix6x6 = compliance.ComplianceMatrix6x6;
pub const ComplianceExtractor = compliance.ComplianceExtractor;
pub const FlexureBlade = flexure.FlexureBlade;
pub const CircularNotchHinge = flexure.CircularNotchHinge;

test {
    _ = mesh;
    _ = solver;
    _ = compliance;
    _ = flexure;
}
