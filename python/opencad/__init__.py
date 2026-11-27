"""
OpenCAD Python SDK: CDML-backed 4-Step Engineering Surface API.
CDML v1.0 Compliant parametric modeling and zero-primitive mathematical kernel.
Executed natively in-process via Python `wasmtime`.
"""

from __future__ import annotations
import os
import re
import struct
import ctypes
from typing import Optional, Dict, Any, List
import wasmtime

# Find cad_core.wasm or cad_kernel.wasm
_POSSIBLE_WASM_PATHS = [
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "kernel-zig", "zig-out", "bin", "cad_kernel.wasm")),
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "kernel-zig", "zig-out", "bin", "cad_core.wasm")),
    os.path.join(os.path.dirname(__file__), "cad_core.wasm"),
    os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "web-app", "public", "cad_core.wasm")),
]


def _resolve_wasm_path() -> str:
    for p in _POSSIBLE_WASM_PATHS:
        if os.path.exists(p):
            return p
    raise RuntimeError("OpenCAD WebAssembly kernel (cad_kernel.wasm / cad_core.wasm) not found!")


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


def _get_base_ptr(mem: Any, store: wasmtime.Store) -> int:
    if isinstance(mem, wasmtime.SharedMemory):
        return ctypes.addressof(mem.data_ptr().contents)
    return ctypes.addressof(mem.data_ptr(store).contents)


def _read_mem_bytes(mem: Any, store: wasmtime.Store, offset: int, length: int) -> bytes:
    base_ptr = _get_base_ptr(mem, store)
    buf = (ctypes.c_ubyte * length).from_address(base_ptr + offset)
    return bytes(buf)


def _write_mem_bytes(mem: Any, store: wasmtime.Store, offset: int, data: bytes) -> None:
    base_ptr = _get_base_ptr(mem, store)
    ctypes.memmove(base_ptr + offset, data, len(data))


def _patch_wasmtime_sharedmemory() -> None:
    if hasattr(wasmtime, "SharedMemory") and hasattr(wasmtime, "_ffi"):
        ffi = wasmtime._ffi
        def _fixed_as_extern(self: Any) -> Any:
            union = ffi.wasmtime_extern_union(sharedmemory=self.ptr())
            return ffi.wasmtime_extern_t(ffi.WASMTIME_EXTERN_SHAREDMEMORY, union)
        wasmtime.SharedMemory._as_extern = _fixed_as_extern


_patch_wasmtime_sharedmemory()


def eval_cdml(xml_string: str, imports_map: Optional[Dict[str, str]] = None) -> CdmlEvaluationResult:
    """Evaluate a raw CDML v1.0 XML document in-process using Python wasmtime."""
    wasm_path = _resolve_wasm_path()

    config = wasmtime.Config()
    config.wasm_threads = True
    config.shared_memory = True
    engine = wasmtime.Engine(config)
    store = wasmtime.Store(engine)
    module = wasmtime.Module.from_file(engine, wasm_path)

    linker = wasmtime.Linker(engine)
    mem: Any = None

    for imp in module.imports:
        if imp.module == "env" and imp.name == "memory":
            if getattr(imp.type, "shared", True):
                mem = wasmtime.SharedMemory(engine, imp.type)
            else:
                mem = wasmtime.Memory(store, imp.type)
            linker.define(store, "env", "memory", mem)

    if mem is None:
        mem = wasmtime.SharedMemory(engine, wasmtime.MemoryType(wasmtime.Limits(128, 2048), shared=True))
        linker.define(store, "env", "memory", mem)

    instance = linker.instantiate(store, module)
    exports = instance.exports(store)

    exports["kernel_init"](store)

    scratch_cursor = 0x300000

    def write_str(s: str) -> tuple[int, int]:
        nonlocal scratch_cursor
        raw = s.encode("utf-8")
        ptr = scratch_cursor
        _write_mem_bytes(mem, store, ptr, raw)
        scratch_cursor = (scratch_cursor + len(raw) + 16) & ~15
        return ptr, len(raw)

    if imports_map:
        reg_fn = exports["cdml_register_import"]
        for path_str, content_str in imports_map.items():
            p_ptr, p_len = write_str(path_str)
            c_ptr, c_len = write_str(content_str)
            reg_fn(store, p_ptr, p_len, c_ptr, c_len)

    doc_ptr, doc_len = write_str(xml_string)
    eval_fn = exports["cdml_eval_document"]
    status = int(eval_fn(store, doc_ptr, doc_len))

    diagnostic = ""
    if status != 0:
        diag_ptr = int(exports["get_string_ptr"](store))
        diag_len = int(exports["get_string_len"](store))
        if diag_ptr and diag_len > 0:
            diagnostic = _read_mem_bytes(mem, store, diag_ptr, diag_len).decode("utf-8", errors="replace")

    probes: Dict[str, float] = {}
    probe_fn = exports["cdml_get_probe_value"]
    for m in re.finditer(r'<probe\s+[^>]*id="([^"]+)"', xml_string):
        pid = m.group(1)
        if pid not in probes:
            p_ptr, p_len = write_str(pid)
            out_ptr = scratch_cursor
            scratch_cursor += 16
            p_res = int(probe_fn(store, p_ptr, p_len, out_ptr))
            if p_res == 0:
                val_bytes = _read_mem_bytes(mem, store, out_ptr, 8)
                probes[pid] = struct.unpack("<d", val_bytes)[0]

    step_str = ""
    step_ptr = int(exports["get_step_ptr"](store))
    step_len = int(exports["get_step_len"](store))
    if step_ptr and step_len > 0:
        step_str = _read_mem_bytes(mem, store, step_ptr, step_len).decode("utf-8", errors="replace")

    stl_bytes = b""
    stl_ptr = int(exports["get_stl_ptr"](store))
    stl_len = int(exports["get_stl_len"](store))
    if stl_ptr and stl_len > 0:
        stl_bytes = _read_mem_bytes(mem, store, stl_ptr, stl_len)

    return CdmlEvaluationResult(
        status=status,
        diagnostic=diagnostic,
        probes=probes,
        step_data=step_str,
        stl_data=stl_bytes,
    )


evalCDML = eval_cdml
