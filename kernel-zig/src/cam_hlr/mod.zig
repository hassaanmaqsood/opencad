pub const hlr = @import("hlr.zig");
pub const section = @import("section.zig");
pub const dxf = @import("dxf.zig");
pub const svg = @import("svg.zig");
pub const threemf = @import("threemf.zig");
pub const nest = @import("nest.zig");
pub const gcode = @import("gcode.zig");
pub const cnc_cam = @import("cnc_cam.zig");
pub const stl_io = @import("stl_io.zig");
pub const wasm = @import("wasm.zig");
pub const c_types = @import("c_types.zig");

pub const LineVisibility = hlr.LineVisibility;
pub const ProjectedCurve2D = hlr.ProjectedCurve2D;
pub const HlrViewPlane = hlr.HlrViewPlane;
pub const HlrDrawingView = hlr.HlrDrawingView;
pub const HlrProjector = hlr.HlrProjector;

pub const SectionPlane = section.SectionPlane;
pub const SectionSlicer = section.SectionSlicer;

pub const DxfExporter = dxf.DxfExporter;
pub const SvgDrawingExporter = svg.SvgDrawingExporter;

pub const ThreeMfPacker = threemf.ThreeMfPacker;
pub const ThreeMfProductionOptions = threemf.ThreeMfProductionOptions;
pub const BuildPlateLimits = threemf.BuildPlateLimits;

pub const NestingMode = nest.NestingMode;
pub const NestingConfig = nest.NestingConfig;
pub const NestingPacker = nest.NestingPacker;
pub const NestingResult = nest.NestingResult;

pub const ToolpathStrategy = cnc_cam.ToolpathStrategy;
pub const ToolDefinition = cnc_cam.ToolDefinition;
pub const CamParams = cnc_cam.CamParams;
pub const CamToolpathResult = cnc_cam.CamToolpathResult;
pub const CncCamGenerator = cnc_cam.CncCamGenerator;

test {
    _ = hlr;
    _ = section;
    _ = dxf;
    _ = svg;
    _ = threemf;
    _ = nest;
    _ = gcode;
    _ = cnc_cam;
    _ = stl_io;
    _ = wasm;
}
