/**
 * @file types.ts
 * Type definitions for @open-cad/core matching abi/cad_kernel.h
 */
export const CAD_INVALID_HANDLE = 0;
export var CadStatus;
(function (CadStatus) {
    CadStatus[CadStatus["Ok"] = 0] = "Ok";
    CadStatus[CadStatus["InvalidArgument"] = 1] = "InvalidArgument";
    CadStatus[CadStatus["OutOfMemory"] = 2] = "OutOfMemory";
    CadStatus[CadStatus["TopologyInvalid"] = 3] = "TopologyInvalid";
    CadStatus[CadStatus["GeometryIntersection"] = 4] = "GeometryIntersection";
    CadStatus[CadStatus["OpFailed"] = 5] = "OpFailed";
    CadStatus[CadStatus["NotImplemented"] = 6] = "NotImplemented";
    CadStatus[CadStatus["Timeout"] = 7] = "Timeout";
    CadStatus[CadStatus["NonManifold"] = 8] = "NonManifold";
    CadStatus[CadStatus["LimitExceeded"] = 9] = "LimitExceeded";
})(CadStatus || (CadStatus = {}));
export var CadBackend;
(function (CadBackend) {
    CadBackend[CadBackend["Auto"] = 0] = "Auto";
    CadBackend[CadBackend["COracle"] = 1] = "COracle";
    CadBackend[CadBackend["NativeZig"] = 2] = "NativeZig";
})(CadBackend || (CadBackend = {}));
export var CadOpType;
(function (CadOpType) {
    CadOpType[CadOpType["PrimitiveBox"] = 0] = "PrimitiveBox";
    CadOpType[CadOpType["PrimitiveCylinder"] = 1] = "PrimitiveCylinder";
    CadOpType[CadOpType["PrimitiveSphere"] = 2] = "PrimitiveSphere";
    CadOpType[CadOpType["SketchExtrude"] = 3] = "SketchExtrude";
    CadOpType[CadOpType["BooleanUnion"] = 4] = "BooleanUnion";
    CadOpType[CadOpType["BooleanDifference"] = 5] = "BooleanDifference";
    CadOpType[CadOpType["BooleanIntersection"] = 6] = "BooleanIntersection";
    CadOpType[CadOpType["Fillet"] = 7] = "Fillet";
    CadOpType[CadOpType["Chamfer"] = 8] = "Chamfer";
    CadOpType[CadOpType["Count"] = 9] = "Count";
})(CadOpType || (CadOpType = {}));
export var CadLodLevel;
(function (CadLodLevel) {
    CadLodLevel[CadLodLevel["Coarse"] = 0] = "Coarse";
    CadLodLevel[CadLodLevel["Medium"] = 1] = "Medium";
    CadLodLevel[CadLodLevel["Fine"] = 2] = "Fine";
})(CadLodLevel || (CadLodLevel = {}));
export var CadSolveState;
(function (CadSolveState) {
    CadSolveState[CadSolveState["Solved"] = 0] = "Solved";
    CadSolveState[CadSolveState["UnderConstrained"] = 1] = "UnderConstrained";
    CadSolveState[CadSolveState["OverConstrained"] = 2] = "OverConstrained";
    CadSolveState[CadSolveState["Conflicting"] = 3] = "Conflicting";
})(CadSolveState || (CadSolveState = {}));
export var CadSketchConstraintType;
(function (CadSketchConstraintType) {
    CadSketchConstraintType[CadSketchConstraintType["Coincident"] = 0] = "Coincident";
    CadSketchConstraintType[CadSketchConstraintType["Parallel"] = 1] = "Parallel";
    CadSketchConstraintType[CadSketchConstraintType["Perpendicular"] = 2] = "Perpendicular";
    CadSketchConstraintType[CadSketchConstraintType["Tangent"] = 3] = "Tangent";
    CadSketchConstraintType[CadSketchConstraintType["Horizontal"] = 4] = "Horizontal";
    CadSketchConstraintType[CadSketchConstraintType["Vertical"] = 5] = "Vertical";
    CadSketchConstraintType[CadSketchConstraintType["Equal"] = 6] = "Equal";
    CadSketchConstraintType[CadSketchConstraintType["Symmetric"] = 7] = "Symmetric";
    CadSketchConstraintType[CadSketchConstraintType["Distance"] = 8] = "Distance";
    CadSketchConstraintType[CadSketchConstraintType["Angle"] = 9] = "Angle";
    CadSketchConstraintType[CadSketchConstraintType["Radius"] = 10] = "Radius";
})(CadSketchConstraintType || (CadSketchConstraintType = {}));
export var CadFeatureType;
(function (CadFeatureType) {
    CadFeatureType[CadFeatureType["Sketch"] = 0] = "Sketch";
    CadFeatureType[CadFeatureType["Extrude"] = 1] = "Extrude";
    CadFeatureType[CadFeatureType["Revolve"] = 2] = "Revolve";
    CadFeatureType[CadFeatureType["BooleanUnion"] = 3] = "BooleanUnion";
    CadFeatureType[CadFeatureType["BooleanCut"] = 4] = "BooleanCut";
    CadFeatureType[CadFeatureType["BooleanIntersect"] = 5] = "BooleanIntersect";
    CadFeatureType[CadFeatureType["Fillet"] = 6] = "Fillet";
    CadFeatureType[CadFeatureType["Chamfer"] = 7] = "Chamfer";
    CadFeatureType[CadFeatureType["Shell"] = 8] = "Shell";
    CadFeatureType[CadFeatureType["Draft"] = 9] = "Draft";
    CadFeatureType[CadFeatureType["CustomPlugin"] = 1000] = "CustomPlugin";
})(CadFeatureType || (CadFeatureType = {}));
export var CadAssemblyMateType;
(function (CadAssemblyMateType) {
    CadAssemblyMateType[CadAssemblyMateType["Coincident"] = 0] = "Coincident";
    CadAssemblyMateType[CadAssemblyMateType["Concentric"] = 1] = "Concentric";
    CadAssemblyMateType[CadAssemblyMateType["Parallel"] = 2] = "Parallel";
    CadAssemblyMateType[CadAssemblyMateType["Distance"] = 3] = "Distance";
    CadAssemblyMateType[CadAssemblyMateType["Angle"] = 4] = "Angle";
    CadAssemblyMateType[CadAssemblyMateType["Gear"] = 5] = "Gear";
})(CadAssemblyMateType || (CadAssemblyMateType = {}));
//# sourceMappingURL=types.js.map