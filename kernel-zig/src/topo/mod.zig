pub const half_edge = @import("half_edge.zig");
pub const topo_naming = @import("topo_naming.zig");
pub const dag = @import("dag.zig");

pub const SoASolid = half_edge.SoASolid;
pub const CadTopoId = half_edge.CadTopoId;
pub const CadSubshapeType = half_edge.CadSubshapeType;
pub const VertexId = half_edge.VertexId;
pub const HalfEdgeId = half_edge.HalfEdgeId;
pub const EdgeId = half_edge.EdgeId;
pub const LoopId = half_edge.LoopId;
pub const FaceId = half_edge.FaceId;
pub const ShellId = half_edge.ShellId;
pub const SolidId = half_edge.SolidId;
pub const INVALID_ID = half_edge.INVALID_ID;
pub const SurfaceType = half_edge.SurfaceType;
pub const BoundingBox = half_edge.BoundingBox;
pub const ManifoldError = half_edge.ManifoldError;

test {
    _ = half_edge;
    _ = topo_naming;
    _ = dag;
    _ = @import("test_topo_suite.zig");
}

