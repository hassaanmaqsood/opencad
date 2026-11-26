# CDML v1.0 Examples Catalog

OpenCAD includes normative parametric parts, implicit TPMS lattices, and multi-physics demo models. Every `.cdml` file is a self-contained executable engineering document that runs in `cad_kernel.wasm`.

---

## 1. Featured Parametric & Multi-Physics Models

| Model | Path | Geometry Formulations | Live Action |
| :--- | :--- | :--- | :--- |
| **Twisted Toroidal Ring (Default Studio Model)** | Built-in (`DEFAULT_TORUS_CDML`) | `0b10` Implicit SDF + Rvachev $C^1$ `r_intersect` + flat $z \ge 0$ print bed base | [Open in Studio ↗](/studio/) |
| **Normative Parametric Flange** | [`/examples/flange_normative.cdml`](/examples/flange_normative.cdml) | `0b00` 2D Householder QR sketch, NURBS outer wire, `<param-curve>` bore, `SE(3)` sweep, and `0b10` Gyroid core | [Open in Studio ↗](/studio/?cdml=/opencad/examples/flange_normative.cdml) |
| **Constrained Mounting Bracket** | [`/examples/constrained_bracket.cdml`](/examples/constrained_bracket.cdml) | `0b00` Multi-constraint 2D sketch + `0b01` boolean union/difference + `<probe type="volume">` | [Open in Studio ↗](/studio/?cdml=/opencad/examples/constrained_bracket.cdml) |
| **FEAScript × OpenCAD Cooling Plate & Disk** | [`examples/feascript-loop/`](/collabs/feascript-thermal-loop) | Closed-loop CDML `<sketch>` to 2D unstructured FEM thermal solve and `0x1F0000` 3D voxel field injection | [Launch Thermal Demo ↗](https://hassaanmaqsood.github.io/opencad/feascript-demo.html) |

---

## 2. Verified Normative Flange Excerpt (`flange_normative.cdml`)

Every tag in the snippet below matches the CDML v1.0 compiler grammar in `kernel-zig/src/cdml/`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <defs>
    <var id="flange_w" value="90.0" unit="mm" min="60.0" max="150.0"/>
    <var id="flange_h" value="16.0" unit="mm" min="8.0"  max="40.0"/>
    <var id="bore_r"   value="15.0" unit="mm" min="8.0"  max="25.0"/>
    <expr id="half_w"  expr="flange_w / 2"/>
    <assert id="bore_clearance"
      expr="half_w - bore_r - 5.0"
      error="bore radius exceeds flange margin"/>
  </defs>

  <body>
    <chart id="chart_xy">
      <vars>
        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="false"/>
      </vars>
      <constraints>
        <residual id="unit_e2"  expr="dot(e2, e2) - 1.0"/>
        <residual id="ortho"    expr="dot(e1, e2)"/>
        <residual id="planar_z" expr="dot(e2, vec3(0, 0, 1))"/>
      </constraints>
    </chart>

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
      <constraints>
        <residual id="cx"     expr="v0.u + v1.u"/>
        <residual id="cy"     expr="v0.v + v3.v"/>
        <residual id="sym"    expr="v2.u + v3.u"/>
        <residual id="h0"     expr="v1.v - v0.v"/>
        <residual id="h1"     expr="v2.v - v3.v"/>
        <residual id="ortho"  expr="dot(v1 - v0, v2 - v1)"/>
        <residual id="width"  expr="norm(v1 - v0) - ref(flange_w)"/>
        <residual id="height" expr="norm(v2 - v1) - ref(flange_w)"/>
      </constraints>
    </sketch>

    <brep id="solid_flange">
      <sweep id="sw_extrude" sketch="sk_flange" cap-ends="true">
        <trajectory>
          <translate x="0" y="0" z-expr="ref(flange_h) * v"/>
        </trajectory>
      </sweep>
    </brep>

    <probe id="housing_volume" type="volume" target="solid_flange"/>
  </body>

  <exports>
    <tessellate target="solid_flange" chord-tol="0.02" angle-tol="0.05"/>
    <step       target="solid_flange" schema="AP214"/>
    <stl        target="solid_flange" binary="true"/>
  </exports>
</cdml>
```

For multi-body boolean and field-driven lattice walkthroughs, see [Complex Examples](/guide/complex-examples).
