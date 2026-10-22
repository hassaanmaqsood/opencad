pub const c_types = @import("c_types.zig");
pub const tet_mesher = @import("tet_mesher.zig");
pub const fea_solver = @import("fea_solver.zig");
pub const flexure_synthesis = @import("flexure_synthesis.zig");
pub const mesh = @import("mesh.zig");
pub const solver = @import("solver.zig");
pub const compliance = @import("compliance.zig");
pub const flexure = @import("flexure.zig");
pub const wasm = @import("wasm.zig");

// Backwards-compatible aliases
pub const TetMesh = tet_mesher.TetMesh;
pub const ElementType = tet_mesher.ElementType;
pub const FeaSolver = fea_solver.FeaSolver;
pub const MaterialProps = solver.MaterialProps;
pub const ComplianceMatrix6x6 = compliance.ComplianceMatrix6x6;
pub const ComplianceExtractor = compliance.ComplianceExtractor;
pub const FlexureBlade = flexure.FlexureBlade;
pub const CircularNotchHinge = flexure_synthesis.CircularNotchHinge;
pub const LeafSpring = flexure_synthesis.LeafSpring;
pub const EllipticalNotchHinge = flexure_synthesis.EllipticalNotchHinge;
pub const CrossAxisFlexurePivot = flexure_synthesis.CrossAxisFlexurePivot;
pub const CartwheelHinge = flexure_synthesis.CartwheelHinge;
pub const BistableBeam = flexure_synthesis.BistableBeam;
pub const FlexureAnalyzer = flexure_synthesis.FlexureAnalyzer;

test {
    _ = c_types;
    _ = tet_mesher;
    _ = fea_solver;
    _ = flexure_synthesis;
    _ = mesh;
    _ = solver;
    _ = compliance;
    _ = flexure;
}
