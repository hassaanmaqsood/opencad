/**
 * @module cdml-presets
 * Parametric CDML v1.0 document generators for the Cooling Plate and Analytical Annular Disk benchmark.
 */

export function buildCoolingPlateCDML(p) {
  const hw = (p.W / 2).toFixed(2);
  const hh = (p.H / 2).toFixed(2);
  return `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <defs>
    <var id="plate_w" value="${p.W.toFixed(2)}" min="60" max="120" unit="mm"/>
    <var id="plate_h" value="${p.H.toFixed(2)}" min="44" max="96" unit="mm"/>
    <var id="plate_t" value="${p.thickness.toFixed(2)}" min="6" max="24" unit="mm"/>
    <var id="hole_r"  value="${p.hole_r.toFixed(2)}" min="5" max="22" unit="mm"/>
    <field-slot id="temp_field" slot="0" semantic="temperature" grid-x="48" grid-y="36" grid-z="4" default="${p.hole_T.toFixed(1)}"/>
    <assert id="wall_margin" expr="(plate_h * 0.5) - hole_r - 5.0" error="hole_r exceeds 5 mm wall margin"/>
  </defs>
  <body>
    <chart id="chart_xy">
      <vars>
        <vec3 id="p0" x="0" y="0" z="0" fixed="true"/>
        <vec3 id="e1" x="1" y="0" z="0" fixed="true"/>
        <vec3 id="e2" x="0" y="1" z="0" fixed="true"/>
      </vars>
    </chart>
    <sketch id="sk_plate" chart="chart_xy" max-iter="50">
      <vars>
        <point2d id="v0" u="-${hw}" v="-${hh}"/>
        <point2d id="v1" u="${hw}"  v="-${hh}"/>
        <point2d id="v2" u="${hw}"  v="${hh}"/>
        <point2d id="v3" u="-${hw}" v="${hh}"/>
      </vars>
      <wire id="wire_outer" closed="true" role="outer">
        <curve id="bottom" degree="1" ctrl="v0 v1" weights="1 1" knots="0 0 1 1"/>
        <curve id="right"  degree="1" ctrl="v1 v2" weights="1 1" knots="0 0 1 1"/>
        <curve id="top"    degree="1" ctrl="v2 v3" weights="1 1" knots="0 0 1 1"/>
        <curve id="left"   degree="1" ctrl="v3 v0" weights="1 1" knots="0 0 1 1"/>
      </wire>
      <wire id="wire_bore" closed="true" role="hole">
        <param-curve id="bore" param="t" domain="0 1"
          u-expr="ref(hole_r) * cos(2 * PI * t)"
          v-expr="ref(hole_r) * sin(2 * PI * t)"/>
      </wire>
    </sketch>
    <brep id="solid_plate">
      <sweep id="sw_plate" sketch="sk_plate" cap-ends="true">
        <trajectory><translate x="0" y="0" z-expr="ref(plate_t) * v"/></trajectory>
      </sweep>
    </brep>
    <probe id="plate_volume" type="volume" target="solid_plate"/>
    <probe id="mean_bore_temp" type="face-mean" target="solid_plate"
           face-predicate="from_id('bore')" quantity="field_scalar(0, x, y, z, ${p.hole_T.toFixed(1)})"/>
  </body>
  <exports>
    <tessellate target="solid_plate" chord-tol="0.02" angle-tol="0.05"/>
    <step target="solid_plate" schema="AP214"/>
    <stl target="solid_plate" binary="true"/>
  </exports>
</cdml>`;
}

export function buildAnnularDiskCDML(p) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <defs>
    <var id="outer_r" value="${p.outer_r.toFixed(2)}" min="18" max="60" unit="mm"/>
    <var id="plate_t" value="${p.thickness.toFixed(2)}" min="4" max="24" unit="mm"/>
    <var id="hole_r"  value="${p.hole_r.toFixed(2)}" min="4" max="22" unit="mm"/>
    <field-slot id="temp_field" slot="0" semantic="temperature" grid-x="48" grid-y="48" grid-z="4" default="${p.hole_T.toFixed(1)}"/>
    <assert id="wall_margin" expr="outer_r - hole_r - 4.0" error="hole_r exceeds 4 mm rim margin"/>
  </defs>
  <body>
    <chart id="chart_xy">
      <vars>
        <vec3 id="p0" x="0" y="0" z="0" fixed="true"/>
        <vec3 id="e1" x="1" y="0" z="0" fixed="true"/>
        <vec3 id="e2" x="0" y="1" z="0" fixed="true"/>
      </vars>
    </chart>
    <sketch id="sk_disk" chart="chart_xy" max-iter="50">
      <wire id="wire_outer" closed="true" role="outer">
        <param-curve id="rim" param="t" domain="0 1"
          u-expr="ref(outer_r) * cos(2 * PI * t)"
          v-expr="ref(outer_r) * sin(2 * PI * t)"/>
      </wire>
      <wire id="wire_bore" closed="true" role="hole">
        <param-curve id="bore" param="t" domain="0 1"
          u-expr="ref(hole_r) * cos(2 * PI * t)"
          v-expr="ref(hole_r) * sin(2 * PI * t)"/>
      </wire>
    </sketch>
    <brep id="solid_plate">
      <sweep id="sw_disk" sketch="sk_disk" cap-ends="true">
        <trajectory><translate x="0" y="0" z-expr="ref(plate_t) * v"/></trajectory>
      </sweep>
    </brep>
    <probe id="plate_volume" type="volume" target="solid_plate"/>
    <probe id="mean_bore_temp" type="face-mean" target="solid_plate"
           face-predicate="from_id('bore')" quantity="field_scalar(0, x, y, z, ${p.hole_T.toFixed(1)})"/>
  </body>
  <exports>
    <tessellate target="solid_plate" chord-tol="0.02" angle-tol="0.05"/>
    <step target="solid_plate" schema="AP214"/>
    <stl target="solid_plate" binary="true"/>
  </exports>
</cdml>`;
}

export function buildCDML(params) {
  return params.modelPreset === 'Annular Disk (Benchmark)'
    ? buildAnnularDiskCDML(params)
    : buildCoolingPlateCDML(params);
}
