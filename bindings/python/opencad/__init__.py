"""
OpenCAD Python SDK: CDML-backed 4-Step Engineering Surface API.
CDML v1.0 Compliant parametric modeling and zero-primitive mathematical kernel.
"""

from __future__ import annotations
import os
import sys
import json
import base64
import subprocess
from typing import Optional, Dict, Any, List, Union

_RUNNER_PATH = os.path.join(os.path.dirname(__file__), "_eval_runner.mjs")

# Find cad_core.wasm or cad_kernel.wasm
_POSSIBLE_WASM_PATHS = [
    os.path.join(os.path.dirname(__file__), "cad_core.wasm"),
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "kernel-zig", "zig-out", "bin", "cad_core.wasm")),
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "web-app", "public", "cad_core.wasm")),
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "kernel-zig", "zig-out", "bin", "cad_kernel.wasm")),
]

_WASM_PATH = None
for p in _POSSIBLE_WASM_PATHS:
    if os.path.exists(p):
        _WASM_PATH = p
        break


class CdmlEvaluationResult:
    """Encapsulates execution status, diagnostics, probes, and export buffers from WASM."""

    def __init__(self, status: int, diagnostic: str, probes: Dict[str, float], step_data: str, stl_data: bytes):
        self.status = status
        self.diagnostic = diagnostic
        self.probes = probes
        self._step = step_data
        self._stl = stl_data

    def probe(self, probe_id: str) -> float:
        return self.probes.get(probe_id, 0.0)

    def to_step(self) -> str:
        return self._step

    def to_stl(self) -> bytes:
        return self._stl

    def __repr__(self) -> str:
        return f"<CdmlEvaluationResult status={self.status} probes={list(self.probes.keys())}>"


class SketchBuilder:
    """Parametric 2D Sketch builder emitting normative CDML v1.0 XML tags (§6)."""

    def __init__(self, doc: CdmlDocument, sketch_id: str, chart: str, max_iter: int = 100):
        self.doc = doc
        self.id = sketch_id
        self.chart = chart
        self.max_iter = max_iter
        self.vars: List[str] = []
        self.wires: List[str] = []
        self.constraints: List[str] = []

    def rect_wire(self, id: str, width: Any, height: Any, role: str = "outer") -> SketchBuilder:
        w_val = str(width)
        h_val = str(height)
        v0, v1, v2, v3 = f"{id}_v0", f"{id}_v1", f"{id}_v2", f"{id}_v3"
        self.vars.extend([
            f'<point2d id="{v0}" u="-40.0" v="-25.0"/>',
            f'<point2d id="{v1}" u="40.0" v="-25.0"/>',
            f'<point2d id="{v2}" u="40.0" v="25.0"/>',
            f'<point2d id="{v3}" u="-40.0" v="25.0"/>',
        ])
        self.wires.append(f"""<wire id="{id}" closed="true" role="{role}">
        <curve id="{id}_seg_bot" degree="1" ctrl="{v0} {v1}" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="{id}_seg_rgt" degree="1" ctrl="{v1} {v2}" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="{id}_seg_top" degree="1" ctrl="{v2} {v3}" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="{id}_seg_lft" degree="1" ctrl="{v3} {v0}" weights="1.0 1.0" knots="0 0 1 1"/>
      </wire>""")
        self.constraints.extend([
            f'<residual id="{id}_cx" expr="{v0}.u + {v1}.u"/>',
            f'<residual id="{id}_cy" expr="{v0}.v + {v3}.v"/>',
            f'<residual id="{id}_sym" expr="{v2}.u + {v3}.u"/>',
            f'<residual id="{id}_h0" expr="{v1}.v - {v0}.v"/>',
            f'<residual id="{id}_h1" expr="{v2}.v - {v3}.v"/>',
            f'<residual id="{id}_ortho" expr="dot({v1}-{v0}, {v2}-{v1})"/>',
            f'<residual id="{id}_width" expr="norm({v1} - {v0}) - {w_val}"/>',
            f'<residual id="{id}_height" expr="norm({v2} - {v1}) - {h_val}"/>',
        ])
        return self

    rectWire = rect_wire

    def circle_wire(self, id: str, radius: Any, role: str = "hole") -> SketchBuilder:
        r_val = str(radius)
        self.wires.append(f"""<wire id="{id}" closed="true" role="{role}">
        <param-curve id="{id}_c" param="t" domain="0 1"
          u-expr="{r_val} * cos(2 * PI * t)"
          v-expr="{r_val} * sin(2 * PI * t)"/>
      </wire>""")
        return self

    circleWire = circle_wire

    def nurbs_curve(self, id: str, degree: int, ctrl: str, weights: str, knots: str) -> SketchBuilder:
        self.wires.append(f'<curve id="{id}" degree="{degree}" ctrl="{ctrl}" weights="{weights}" knots="{knots}"/>')
        return self

    nurbsCurve = nurbs_curve

    def param_curve(self, id: str, param: str, domain: str, u_expr: str, v_expr: str) -> SketchBuilder:
        self.wires.append(f'<param-curve id="{id}" param="{param}" domain="{domain}" u-expr="{u_expr}" v-expr="{v_expr}"/>')
        return self

    paramCurve = param_curve

    def to_xml(self) -> str:
        vars_xml = "\n        ".join(self.vars)
        wires_xml = "\n      ".join(self.wires)
        constraints_xml = "\n        ".join(self.constraints)
        res = f'    <sketch id="{self.id}" chart="{self.chart}" max-iter="{self.max_iter}">\n'
        if self.vars:
            res += f'      <vars>\n        {vars_xml}\n      </vars>\n'
        if self.wires:
            res += f'      {wires_xml}\n'
        if self.constraints:
            res += f'      <constraints>\n        {constraints_xml}\n      </constraints>\n'
        res += '    </sketch>'
        return res

    def __getattr__(self, name: str) -> Any:
        return getattr(self.doc, name)


class BrepBuilder:
    """B-Rep Solid builder with kinematic sweeps, lofts, fillets, and shells (§7)."""

    def __init__(self, doc: CdmlDocument, brep_id: str, material: Optional[str] = None):
        self.doc = doc
        self.id = brep_id
        self.material = material
        self.operations: List[str] = []

    def sweep_extrude(self, id: str, sketch: str, z_expr: str = "16.0 * v", cap_ends: bool = True) -> BrepBuilder:
        cap_str = "true" if cap_ends else "false"
        self.operations.append(f"""      <sweep id="{id}" sketch="{sketch}" cap-ends="{cap_str}">
        <trajectory>
          <translate x="0" y="0" z-expr="{z_expr}"/>
        </trajectory>
      </sweep>""")
        return self

    sweepExtrude = sweep_extrude

    def fillet(self, id: str, edge_predicate: str, radius_expr: Any) -> BrepBuilder:
        self.operations.append(f'      <fillet id="{id}" edge-predicate="{edge_predicate}" radius-expr="{radius_expr}"/>')
        return self

    def to_xml(self) -> str:
        mat_attr = f' material="{self.material}"' if self.material else ""
        ops_xml = "\n".join(self.operations)
        return f'    <brep id="{self.id}"{mat_attr}>\n{ops_xml}\n    </brep>'

    def __getattr__(self, name: str) -> Any:
        return getattr(self.doc, name)


class CdmlDocument:
    """CDML v1.0 Document Builder & Surface API."""

    def __init__(self, units: str = "mm", linear_tol: str = "1e-7", angular_tol: str = "1e-11"):
        self.units = units
        self.linear_tol = linear_tol
        self.angular_tol = angular_tol
        self.imports: List[str] = []
        self.defs: List[str] = []
        self.charts: List[str] = []
        self.sketches: List[SketchBuilder] = []
        self.breps: List[BrepBuilder] = []
        self.probes: List[str] = []
        self.exports: List[str] = []
        self.raw_elements: List[str] = []
        self.active_sketch: Optional[SketchBuilder] = None
        self.active_brep: Optional[BrepBuilder] = None

    def import_doc(self, src: str, prefix: Optional[str] = None) -> CdmlDocument:
        p_attr = f' prefix="{prefix}"' if prefix else ""
        self.imports.append(f'<import src="{src}"{p_attr}/>')
        return self

    def var(self, id: str, value: Any, min: Optional[float] = None, max: Optional[float] = None, unit: Optional[str] = None) -> CdmlDocument:
        u_attr = f' unit="{unit}"' if unit else f' unit="{self.units}"'
        min_attr = f' min="{min}"' if min is not None else ""
        max_attr = f' max="{max}"' if max is not None else ""
        self.defs.append(f'<var id="{id}" value="{value}"{u_attr}{min_attr}{max_attr}/>')
        return self

    def expr(self, id: str, expr_str: str) -> CdmlDocument:
        self.defs.append(f'<expr id="{id}" expr="{expr_str}"/>')
        return self

    def field_slot(self, id: str, slot: int, semantic: str = "stress", grid_x: int = 64, grid_y: int = 64, grid_z: int = 24, default_val: float = 40.0) -> CdmlDocument:
        self.defs.append(f'<field-slot id="{id}" slot="{slot}" semantic="{semantic}" grid-x="{grid_x}" grid-y="{grid_y}" grid-z="{grid_z}" default="{default_val}"/>')
        return self

    def chart_xy(self, id: str) -> CdmlDocument:
        xml = f"""    <chart id="{id}">
      <vars>
        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="false"/>
      </vars>
      <constraints>
        <residual id="unit_e2" expr="dot(e2, e2) - 1.0"/>
        <residual id="ortho" expr="dot(e1, e2)"/>
        <residual id="planar_z" expr="dot(e2, vec3(0, 0, 1))"/>
      </constraints>
    </chart>"""
        self.charts.append(xml)
        return self

    chartXY = chart_xy

    def sketch(self, id: str, chart: str, max_iter: int = 100) -> SketchBuilder:
        sb = SketchBuilder(self, id, chart, max_iter)
        self.sketches.append(sb)
        self.active_sketch = sb
        return sb

    def brep(self, id: str, material: Optional[str] = None) -> BrepBuilder:
        bb = BrepBuilder(self, id, material)
        self.breps.append(bb)
        self.active_brep = bb
        return bb

    def probe(self, id: str, type: str = "volume", target: str = "", face_predicate: Optional[str] = None, quantity: Optional[str] = None) -> CdmlDocument:
        fp_attr = f' face-predicate="{face_predicate}"' if face_predicate else ""
        q_attr = f' quantity="{quantity}"' if quantity else ""
        self.probes.append(f'<probe id="{id}" type="{type}" target="{target}"{fp_attr}{q_attr}/>')
        return self

    def export_tessellate(self, target: str, chord_tol: float = 0.02, angle_tol: float = 0.05) -> CdmlDocument:
        self.exports.append(f'<tessellate target="{target}" chord-tol="{chord_tol}" angle-tol="{angle_tol}"/>')
        return self

    exportTessellate = export_tessellate

    def export_step(self, target: str, schema: str = "AP214") -> CdmlDocument:
        self.exports.append(f'<step target="{target}" schema="{schema}"/>')
        return self

    exportStep = export_step

    def export_stl(self, target: str, binary: bool = True) -> CdmlDocument:
        b_str = "true" if binary else "false"
        self.exports.append(f'<stl target="{target}" binary="{b_str}"/>')
        return self

    exportStl = export_stl

    def to_cdml(self) -> str:
        xml = ['<?xml version="1.0" encoding="UTF-8"?>']
        xml.append(f'<cdml version="1.0" units="{self.units}" linear_tol="{self.linear_tol}" angular_tol="{self.angular_tol}">')
        if self.imports:
            xml.append('  <imports>')
            for imp in self.imports:
                xml.append(f'    {imp}')
            xml.append('  </imports>')
        if self.defs:
            xml.append('  <defs>')
            for df in self.defs:
                xml.append(f'    {df}')
            xml.append('  </defs>')
        xml.append('  <body>')
        for c in self.charts:
            xml.append(c)
        for s in self.sketches:
            xml.append(s.to_xml())
        for b in self.breps:
            xml.append(b.to_xml())
        for p in self.probes:
            xml.append(f'    {p}')
        xml.append('  </body>')
        if self.exports:
            xml.append('  <exports>')
            for exp in self.exports:
                xml.append(f'    {exp}')
            xml.append('  </exports>')
        xml.append('</cdml>')
        return "\n".join(xml)

    toCDML = to_cdml

    def evaluate(self, imports_map: Optional[Dict[str, str]] = None) -> CdmlEvaluationResult:
        return eval_cdml(self.to_cdml(), imports_map)


def cdml(units: str = "mm", linear_tol: str = "1e-7", angular_tol: str = "1e-11") -> CdmlDocument:
    """Create a new CDML v1.0 parametric document builder."""
    return CdmlDocument(units=units, linear_tol=linear_tol, angular_tol=angular_tol)


def eval_cdml(xml_string: str, imports_map: Optional[Dict[str, str]] = None) -> CdmlEvaluationResult:
    """Evaluate a raw CDML v1.0 XML document in cad_core.wasm."""
    wasm_path = _WASM_PATH
    if not wasm_path or not os.path.exists(wasm_path):
        raise RuntimeError("OpenCAD WebAssembly kernel (cad_core.wasm) not found!")

    payload = json.dumps({
        "wasmPath": wasm_path,
        "xml": xml_string,
        "imports": imports_map or {},
    })

    proc = subprocess.run(
        ["node", _RUNNER_PATH],
        input=payload,
        capture_output=True,
        text=True,
    )

    if proc.returncode != 0:
        raise RuntimeError(f"CDML evaluator execution error: {proc.stderr}")

    out_data = json.loads(proc.stdout)
    stl_bytes = base64.b64decode(out_data.get("stl_base64", "")) if out_data.get("stl_base64") else b""

    return CdmlEvaluationResult(
        status=out_data.get("status", -1),
        diagnostic=out_data.get("diagnostic", ""),
        probes=out_data.get("probes", {}),
        step_data=out_data.get("step", ""),
        stl_data=stl_bytes,
    )


evalCDML = eval_cdml
