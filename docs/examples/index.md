# CDML v1.0 Examples Catalog

OpenCAD includes normative parametric parts, implicit TPMS lattices, and multi-physics demo models. Every `.cdml` file is a self-contained **executable engineering document** that compiles in `cad_kernel.wasm`.

---

## 1. Featured Parametric & Multi-Physics Models

| Model | Path | Geometry Formulations Demonstrated | Live Action |
| :--- | :--- | :--- | :--- |
| **Twisted Toroidal Ring (Default Studio Model)** | Built-in (`DEFAULT_TORUS_CDML`) | `0b10` Implicit SDF + Rvachev $C^1$ `r_intersect` + support-free flat $z \ge 0$ print bed base | [Open in Studio ↗](https://hassaanmaqsood.github.io/opencad/) |
| **Normative Parametric Flange** | [`/examples/flange_normative.cdml`](/examples/flange_normative.cdml) | `0b00` 2D Householder QR constrained `<sketch>`, degree-1 NURBS `<curve>` outer wire, `<param-curve>` bore, and kinematic `SE(3)` extrusion sweep | [Download `.cdml`](/examples/flange_normative.cdml) |
| **Constrained Mounting Bracket** | [`/examples/constrained_bracket.cdml`](/examples/constrained_bracket.cdml) | `0b00` Multi-constraint 2D sketch + `0b01` boolean union/difference + `<probe type="volume">` | [Download `.cdml`](/examples/constrained_bracket.cdml) |
| **FEAScript × OpenCAD Cooling Plate & Disk** | [`examples/feascript-loop/`](/collabs/feascript-thermal-loop) | Closed-loop CDML `<sketch>` $\rightarrow$ 2D unstructured FEM thermal solve $\rightarrow$ `0x1F0000` 3D voxel field injection | [Launch Thermal Demo ↗](https://hassaanmaqsood.github.io/opencad/feascript-demo.html) |

---

## 2. Normative Flange Example (`flange_normative.cdml`)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <defs>
    <var id="flange_w" value="90.0" unit="mm" min="50.0" max="140.0" public="true"/>
    <var id="flange_h" value="14.0" unit="mm" min="6.0"  max="30.0"  public="true"/>
    <var id="bore_r"   value="18.0" unit="mm" min="8.0"  max="35.0"  public="true"/>
    <expr id="half_w"  expr="ref(flange_w) * 0.5"/>
    <chart id="chart_xy" origin="0 0 0" normal="0 0 1" x-axis="1 0 0"/>
  </defs>

  <body>
    <sketch id="sk_flange" chart="chart_xy" max-iter="100">
      <vars>
        <point2d id="v0" u="-45.0" v="-45.0"/>
        <point2d id="v1" u=" 45.0" v="-45.0"/>
        <point2d id="v2" u=" 45.0" v=" 45.0"/>
        <point2d id="v3" u="-45.0" v=" 45.0"/>
      </vars>
      <wire id="wire_outer" closed="true" role="outer">
        <curve id="seg_bot" degree="1" ctrl="v0 v1" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_rgt" degree="1" ctrl="v1 v2" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_top" degree="1" ctrl="v2 v3" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_lft" degree="1" ctrl="v3 v0" weights="1.0 1.0" knots="0 0 1 1"/>
      </wire>
      <wire id="wire_bore" closed="true" role="hole">
        <param-curve id="c_bore" param="t" domain="0 1"
          u-expr="ref(bore_r) * cos(2 * PI * t)"
          v-expr="ref(bore_r) * sin(2 * PI * t)"/>
      </wire>
    </sketch>

    <brep id="flange_body">
      <sweep id="sw_base" profile="sk_flange" domain="0 1">
        <se3-translation x-expr="0" y-expr="0" z-expr="ref(flange_h) * v"/>
      </sweep>
    </brep>

    <probe id="part_volume" type="volume" target="flange_body"/>
  </body>

  <exports>
    <tessellate target="flange_body" chord-tol="0.02" angle-tol="0.05"/>
    <step       target="flange_body" schema="AP214"/>
    <stl        target="flange_body" binary="true"/>
  </exports>
</cdml>
```

For more advanced multi-body boolean and field-driven lattice examples, see [Complex Examples Walkthrough](/guide/complex-examples).
