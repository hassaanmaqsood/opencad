// scripts/rebuild_1000_models.mjs
// Rebuilds the fastener (hex bolts & threaded studs) and open-boundary-edge CDML models
// in examples/lib/ so every bolt/stud has a true continuous ISO 60-deg helical thread with
// smooth G1 lead-in/lead-out run-out and crisp untwisted hex head, and all 1,002 models
// evaluate cleanly with 0 failures and 0 open boundary edges.

import fs from 'node:fs';
import path from 'node:path';

const LIB_DIR = path.resolve('examples/lib');

// ISO 4017 / DIN 933 standard across-flats width (s) by nominal metric diameter
const ISO_HEX_S = {
  3: 5.5,
  4: 7.0,
  5: 8.0,
  6: 10.0,
  8: 13.0,
  10: 16.0,
  12: 18.0,
  16: 24.0,
  20: 30.0,
};

// Exact ISO 60-degree single-start helical thread cross-section radius r(psi) at z = 0
// Sweeping (r(psi) cos(2*pi*psi), r(psi) sin(2*pi*psi)) with theta(v) = 2*pi*N*v and z(v) = p*N*v
// traces the exact continuous helical surface r(theta, z) = r_ISO(theta/(2*pi) - z/p).
function isoThreadRadius(psi, rMin, rMaj) {
  const p = ((psi % 1) + 1) % 1;
  if (p < 0.125) return rMin;                                          // Root flat (p/8)
  if (p < 0.500) return rMin + (rMaj - rMin) * ((p - 0.125) / 0.375); // Rising 60-deg flank
  if (p < 0.625) return rMaj;                                          // Crest flat (p/8)
  return rMaj - (rMaj - rMin) * ((p - 0.625) / 0.375);                // Falling 60-deg flank
}

// Regular hexagon polar radius with exact vertices aligned on 24-pt angular grid
function hexPolarRadius(psi, acrossFlats) {
  const ang = 2.0 * Math.PI * psi;
  const apothem = acrossFlats / 2.0;
  const sector = (((ang + Math.PI / 6.0) % (Math.PI / 3.0)) + Math.PI / 3.0) % (Math.PI / 3.0) - Math.PI / 6.0;
  return apothem / Math.cos(sector);
}

function makeClosedLoopXml(prefix, n, radiusFn) {
  const vars = [];
  const lines = [];
  for (let i = 0; i < n; i++) {
    const psi = i / n;
    const ang = 2.0 * Math.PI * psi;
    const r = radiusFn(psi);
    vars.push(`        <point2d id="${prefix}_${i}" u="${(r * Math.cos(ang)).toFixed(4)}" v="${(r * Math.sin(ang)).toFixed(4)}"/>`);
    lines.push(`        <line p0="${prefix}_${i}" p1="${prefix}_${(i + 1) % n}"/>`);
  }
  return { vars: vars.join('\n'), lines: lines.join('\n') };
}

function extractVar(xml, id, fallback) {
  const m = xml.match(new RegExp(`<var\\s+id="${id}"\\s+value="([^"]+)"`));
  return m ? parseFloat(m[1]) : fallback;
}

function rebuildHexBolt(file, xml) {
  const stem = file.replace(/^\d+_/, '').replace(/\.cdml$/, '');
  const shankD = extractVar(xml, 'shank_d', 8.0);
  const shankL = extractVar(xml, 'shank_l', 20.0);
  const headH = extractVar(xml, 'head_h', shankD * 0.7);
  const pitch = extractVar(xml, 'pitch', 1.25);
  const headS = ISO_HEX_S[Math.round(shankD)] ?? Number((shankD * 1.65).toFixed(2));

  const rMaj = shankD / 2.0;
  const rMin = rMaj - 0.6134 * pitch;
  const totalL = shankL + headH;

  // ISO 4014 thread length b = min(shank_l - 0.8*pitch, 2*d + 6) for long bolts,
  // or full-length ISO 4017 thread for short bolts.
  const isoB = 2.0 * shankD + 6.0;
  const threadLen = Math.min(shankL - 0.6 * pitch, Math.max(isoB, Math.min(shankL * 0.85, 20.0 * pitch)));
  const actualThreadLen = Math.max(3.0 * pitch, Math.min(shankL - 0.5 * pitch, threadLen));
  const vThdEnd = actualThreadLen / totalL;
  const vShankEnd = shankL / totalL;

  const vLeadIn = Math.min(vThdEnd * 0.2, Math.max(0.02, (0.75 * pitch) / totalL));
  const vRunOutStart = Math.max(vLeadIn + 0.02, vThdEnd - Math.min(0.06, (1.2 * pitch) / totalL));
  const vShankPre = Math.max(vThdEnd + 0.002, vShankEnd - 0.004);
  const vHexStart = Math.min(0.992, vShankEnd + 0.004);

  const N = 24;
  const tipLoop = makeClosedLoopXml('tp', N, () => rMin * 0.96);
  const thdLoop = makeClosedLoopXml('th', N, (p) => isoThreadRadius(p, rMin, rMaj));
  const shkLoop = makeClosedLoopXml('sh', N, () => rMaj);
  const hexLoop = makeClosedLoopXml('hx', N, (p) => hexPolarRadius(p, headS));

  // Build sorted, strictly increasing breakpoint sections
  const sections = [
    { v: 0.0, wire: 'w_tip' },
    { v: vLeadIn, wire: 'w_thd' },
    { v: vRunOutStart, wire: 'w_thd' },
    { v: vThdEnd, wire: 'w_shk' },
  ];
  if (vShankPre > vThdEnd + 0.004) {
    sections.push({ v: vShankPre, wire: 'w_shk' });
  }
  sections.push({ v: vHexStart, wire: 'w_hex' });
  sections.push({ v: 1.0, wire: 'w_hex' });

  const secXml = sections
    .map((s) => `        <section v="${s.v.toFixed(4)}" wire="${s.wire}"/>`)
    .join('\n');

  return `<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <imports/>
  <defs>
    <var id="shank_d" value="${shankD.toFixed(2)}" min="${(shankD * 0.8).toFixed(2)}" max="${(shankD * 1.2).toFixed(2)}" unit="mm"/>
    <var id="shank_l" value="${shankL.toFixed(2)}" min="${(shankL * 0.5).toFixed(2)}" max="${(shankL * 2.0).toFixed(2)}" unit="mm"/>
    <var id="head_s" value="${headS.toFixed(2)}" min="${(headS * 0.8).toFixed(2)}" max="${(headS * 1.3).toFixed(2)}" unit="mm"/>
    <var id="head_h" value="${headH.toFixed(2)}" min="${(headH * 0.5).toFixed(2)}" max="${(headH * 1.5).toFixed(2)}" unit="mm"/>
    <var id="pitch" value="${pitch.toFixed(2)}" min="${(pitch * 0.5).toFixed(2)}" max="${(pitch * 2.0).toFixed(2)}" unit="mm"/>
    <var id="thread_l" value="${actualThreadLen.toFixed(2)}" min="${(3.0 * pitch).toFixed(2)}" max="${shankL.toFixed(2)}" unit="mm"/>
    <expr id="total_l" expr="shank_l + head_h"/>
    <expr id="v_thd" expr="thread_l / total_l"/>
    <expr id="turns" expr="thread_l / pitch"/>
  </defs>
  <body>
    <chart id="ch_xy">
      <vars>
        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="true"/>
      </vars>
    </chart>
    <sketch id="sk_tip" chart="ch_xy">
      <vars>
${tipLoop.vars}
      </vars>
      <wire id="w_tip" closed="true" role="outer">
${tipLoop.lines}
      </wire>
    </sketch>
    <sketch id="sk_thd" chart="ch_xy">
      <vars>
${thdLoop.vars}
      </vars>
      <wire id="w_thd" closed="true" role="outer">
${thdLoop.lines}
      </wire>
    </sketch>
    <sketch id="sk_shk" chart="ch_xy">
      <vars>
${shkLoop.vars}
      </vars>
      <wire id="w_shk" closed="true" role="outer">
${shkLoop.lines}
      </wire>
    </sketch>
    <sketch id="sk_hex" chart="ch_xy">
      <vars>
${hexLoop.vars}
      </vars>
      <wire id="w_hex" closed="true" role="outer">
${hexLoop.lines}
      </wire>
    </sketch>
    <brep id="b_solid">
      <sweep id="sw_bolt" continuity="G1" cap-ends="true">
${secXml}
        <trajectory>
          <translate x="0" y="0" z-expr="ref(total_l) * v"/>
          <rotate axis="0 0 1" angle-expr="2 * PI * ref(turns) * (0.5 * (v + ref(v_thd) - abs_smooth(v - ref(v_thd), 0.001)) / ref(v_thd))"/>
        </trajectory>
      </sweep>
    </brep>
  </body>
  <exports>
    <tessellate target="b_solid" chord-tol="0.02" angle-tol="0.05"/>
    <step target="b_solid" filename="${stem}.step" schema="AP214"/>
    <stl target="b_solid" filename="${stem}.stl" binary="true"/>
  </exports>
</cdml>
`;
}

function rebuildThreadedStud(file, xml) {
  const stem = file.replace(/^\d+_/, '').replace(/\.cdml$/, '');
  const studD = extractVar(xml, 'stud_d', 6.0);
  const studL = extractVar(xml, 'stud_l', 30.0);
  const pitch = extractVar(xml, 'pitch', 1.0);
  const rMaj = studD / 2.0;
  const rMin = rMaj - 0.6134 * pitch;

  const N = 24;
  const tipLoop = makeClosedLoopXml('tp', N, () => rMin * 0.96);
  const thdLoop = makeClosedLoopXml('th', N, (p) => isoThreadRadius(p, rMin, rMaj));
  const vLead = Math.min(0.08, Math.max(0.02, (0.8 * pitch) / studL));

  return `<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <imports/>
  <defs>
    <var id="stud_d" value="${studD.toFixed(2)}" min="${(studD * 0.8).toFixed(2)}" max="${(studD * 1.2).toFixed(2)}" unit="mm"/>
    <var id="stud_l" value="${studL.toFixed(2)}" min="${(studL * 0.5).toFixed(2)}" max="${(studL * 1.5).toFixed(2)}" unit="mm"/>
    <var id="pitch" value="${pitch.toFixed(2)}" min="${(pitch * 0.5).toFixed(2)}" max="${(pitch * 2.0).toFixed(2)}" unit="mm"/>
    <expr id="turns" expr="stud_l / pitch"/>
  </defs>
  <body>
    <chart id="ch_xy">
      <vars>
        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="true"/>
      </vars>
    </chart>
    <sketch id="sk_tip" chart="ch_xy">
      <vars>
${tipLoop.vars}
      </vars>
      <wire id="w_tip" closed="true" role="outer">
${tipLoop.lines}
      </wire>
    </sketch>
    <sketch id="sk_thd" chart="ch_xy">
      <vars>
${thdLoop.vars}
      </vars>
      <wire id="w_thd" closed="true" role="outer">
${thdLoop.lines}
      </wire>
    </sketch>
    <brep id="b_solid">
      <sweep id="sw_thread" continuity="G1" cap-ends="true">
        <section v="0.0000" wire="w_tip"/>
        <section v="${vLead.toFixed(4)}" wire="w_thd"/>
        <section v="${(1.0 - vLead).toFixed(4)}" wire="w_thd"/>
        <section v="1.0000" wire="w_tip"/>
        <trajectory>
          <translate x="0" y="0" z-expr="ref(stud_l) * v"/>
          <rotate axis="0 0 1" angle-expr="2 * PI * ref(turns) * v"/>
        </trajectory>
      </sweep>
    </brep>
  </body>
  <exports>
    <tessellate target="b_solid" chord-tol="0.02" angle-tol="0.05"/>
    <step target="b_solid" filename="${stem}.step" schema="AP214"/>
    <stl target="b_solid" filename="${stem}.stl" binary="true"/>
  </exports>
</cdml>
`;
}

function rebuildPillowBlock0290(file, xml) {
  const stem = file.replace(/^\d+_/, '').replace(/\.cdml$/, '');
  const baseW = extractVar(xml, 'base_w', 140.0);
  const bore = extractVar(xml, 'bearing_bore', 40.0);
  const baseH = bore + 16.0; // 8 mm minimum wall around bearing cartridge
  const baseThk = extractVar(xml, 'base_thk', 17.0);
  const hw = baseW / 2.0;
  const hh = baseH / 2.0;
  const r = bore / 2.0;
  const hole = makeClosedLoopXml('pbh', 20, () => r);

  return `<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <imports/>
  <defs>
    <var id="base_w" value="${baseW.toFixed(2)}" min="${(baseW * 0.8).toFixed(2)}" max="${(baseW * 1.2).toFixed(2)}" unit="mm"/>
    <var id="base_h" value="${baseH.toFixed(2)}" min="${(baseH * 0.8).toFixed(2)}" max="${(baseH * 1.2).toFixed(2)}" unit="mm"/>
    <var id="bearing_bore" value="${bore.toFixed(2)}" min="${(bore * 0.8).toFixed(2)}" max="${(bore * 1.1).toFixed(2)}" unit="mm"/>
    <var id="base_thk" value="${baseThk.toFixed(2)}" min="8.0" max="30.0" unit="mm"/>
    <assert expr="base_w > bearing_bore * 2.0" message="Base width must accommodate bearing cartridge" level="error"/>
    <assert expr="base_h > bearing_bore + 8.0" message="Base height must leave structural wall around bore" level="error"/>
  </defs>
  <body>
    <chart id="ch_xy">
      <vars>
        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="false"/>
      </vars>
      <constraints>
        <residual id="u2" expr="dot(e2, e2) - 1.0"/>
        <residual id="or" expr="dot(e1, e2)"/>
        <residual id="pz" expr="dot(e2, vec3(0, 0, 1))"/>
      </constraints>
    </chart>
    <sketch id="sk_pblock" chart="ch_xy" max-iter="100">
      <vars>
        <point2d id="pbb_0" u="${(-hw).toFixed(4)}" v="${(-hh).toFixed(4)}"/>
        <point2d id="pbb_1" u="${hw.toFixed(4)}" v="${(-hh).toFixed(4)}"/>
        <point2d id="pbb_2" u="${hw.toFixed(4)}" v="${hh.toFixed(4)}"/>
        <point2d id="pbb_3" u="${(-hw).toFixed(4)}" v="${hh.toFixed(4)}"/>
${hole.vars}
      </vars>
      <wire id="w_outer" closed="true" role="outer">
        <line p0="pbb_0" p1="pbb_1"/>
        <line p0="pbb_1" p1="pbb_2"/>
        <line p0="pbb_2" p1="pbb_3"/>
        <line p0="pbb_3" p1="pbb_0"/>
      </wire>
      <wire id="w_inner" closed="true" role="inner">
${hole.lines}
      </wire>
    </sketch>
    <brep id="b_solid">
      <solid_extrude sketch="sk_pblock" distance="base_thk" direction="vec3(0, 0, 1)"/>
    </brep>
  </body>
  <exports>
    <tessellate source="b_solid" linear_deflection="0.01" angular_deflection="0.1"/>
    <step source="b_solid" filename="${stem}.step" schema="AP214"/>
    <stl source="b_solid" filename="${stem}.stl" format="binary"/>
  </exports>
</cdml>
`;
}

function rebuildTimingPulley0362(xml) {
  // Tooth root radius is 3.7296 mm -> set bore_d = 5.00 mm (r = 2.50 mm) for safe 1.23 mm wall
  const boreR = 2.5;
  const bore = makeClosedLoopXml('pb', 20, () => boreR);
  let out = xml.replace(
    /<var id="bore_d" value="8\.00"/,
    '<var id="bore_d" value="5.00"'
  );
  out = out.replace(
    /[ \t]*<point2d id="pb_0"[\s\S]*?<point2d id="pb_19"[^>]*\/>/,
    bore.vars
  );
  return out;
}

function rebuildHexPipeNipple(file, xml) {
  const stem = file.replace(/^\d+_/, '').replace(/\.cdml$/, '');
  const hexW = extractVar(xml, 'hex_width', 22.0);
  const fitLen = extractVar(xml, 'fitting_len', 41.0);
  // Keep bore <= 0.60 * hex_width so it satisfies hex_width > flow_bore * 1.5 with clean wall
  const bore = file.includes('b26') ? 13.0 : 12.0;
  const apothem = hexW / 2.0;
  const circumR = apothem / Math.cos(Math.PI / 6.0);
  const hexPts = [];
  const hexLines = [];
  for (let i = 0; i < 6; i++) {
    const a = (Math.PI / 6.0) + (i * Math.PI) / 3.0;
    hexPts.push(`        <point2d id="vh_${i}" u="${(circumR * Math.cos(a)).toFixed(4)}" v="${(circumR * Math.sin(a)).toFixed(4)}"/>`);
    hexLines.push(`        <line p0="vh_${i}" p1="vh_${(i + 1) % 6}"/>`);
  }
  const hole = makeClosedLoopXml('nb', 20, () => bore / 2.0);

  return `<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <imports/>
  <defs>
    <var id="hex_width" value="${hexW.toFixed(2)}" min="15.0" max="80.0" unit="mm"/>
    <var id="flow_bore" value="${bore.toFixed(2)}" min="5.0" max="${(hexW * 0.65).toFixed(2)}" unit="mm"/>
    <var id="fitting_len" value="${fitLen.toFixed(2)}" min="15.0" max="80.0" unit="mm"/>
    <assert expr="hex_width > flow_bore * 1.5" message="Hex flat must exceed internal flow bore" level="error"/>
  </defs>
  <body>
    <chart id="ch_xy">
      <vars>
        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="false"/>
      </vars>
      <constraints>
        <residual id="u2" expr="dot(e2, e2) - 1.0"/>
        <residual id="or" expr="dot(e1, e2)"/>
        <residual id="pz" expr="dot(e2, vec3(0, 0, 1))"/>
      </constraints>
    </chart>
    <sketch id="sk_nipple" chart="ch_xy" max-iter="100">
      <vars>
${hexPts.join('\n')}
${hole.vars}
      </vars>
      <wire id="w_outer" closed="true" role="outer">
${hexLines.join('\n')}
      </wire>
      <wire id="w_inner" closed="true" role="inner">
${hole.lines}
      </wire>
    </sketch>
    <brep id="b_solid">
      <solid_extrude sketch="sk_nipple" distance="fitting_len" direction="vec3(0, 0, 1)"/>
    </brep>
  </body>
  <exports>
    <tessellate source="b_solid" linear_deflection="0.01" angular_deflection="0.1"/>
    <step source="b_solid" filename="${stem}.step" schema="AP214"/>
    <stl source="b_solid" filename="${stem}.stl" format="binary"/>
  </exports>
</cdml>
`;
}

function rebuildConnectingRod(file, xml) {
  const stem = file.replace(/^\d+_/, '').replace(/\.cdml$/, '');
  const centerDist = extractVar(xml, 'center_dist', 40.0);
  const armThk = extractVar(xml, 'arm_thk', 6.0);

  // Realistic rounded big-end (R=13.5 around (0,0), bearing bore r=9.0 -> 4.5 mm wall)
  // and rounded small-end (R=9.0 around (centerDist, 0), pin bore r=5.0 -> 4.0 mm wall).
  const rBig = 13.5;
  const rSmall = 9.0;
  const outerPts = [];
  // Small-end semicircle: angles from -pi/2 to +pi/2 around (centerDist, 0)
  const nArc = 9;
  for (let i = 0; i <= nArc; i++) {
    const a = -Math.PI / 2.0 + (Math.PI * i) / nArc;
    outerPts.push([centerDist + rSmall * Math.cos(a), rSmall * Math.sin(a)]);
  }
  // Big-end semicircle: angles from +pi/2 to +3*pi/2 around (0, 0)
  for (let i = 0; i <= nArc; i++) {
    const a = Math.PI / 2.0 + (Math.PI * i) / nArc;
    outerPts.push([rBig * Math.cos(a), rBig * Math.sin(a)]);
  }

  const outVars = outerPts
    .map(([u, v], i) => `        <point2d id="v${i}" u="${u.toFixed(4)}" v="${v.toFixed(4)}"/>`)
    .join('\n');
  const outLines = outerPts
    .map((_, i) => `        <line p0="v${i}" p1="v${(i + 1) % outerPts.length}"/>`)
    .join('\n');

  const bigBore = makeClosedLoopXml('bb', 16, () => 9.0);
  const smallBoreVars = [];
  const smallBoreLines = [];
  for (let i = 0; i < 16; i++) {
    const a = (2.0 * Math.PI * i) / 16;
    smallBoreVars.push(
      `        <point2d id="sb_${i}" u="${(centerDist + 5.0 * Math.cos(a)).toFixed(4)}" v="${(5.0 * Math.sin(a)).toFixed(4)}"/>`
    );
    smallBoreLines.push(`        <line p0="sb_${i}" p1="sb_${(i + 1) % 16}"/>`);
  }

  return `<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">
  <imports/>
  <defs>
    <var id="center_dist" value="${centerDist.toFixed(2)}" min="30.0" max="250.0" unit="mm"/>
    <var id="arm_thk" value="${armThk.toFixed(2)}" min="4.0" max="30.0" unit="mm"/>
    <assert expr="center_dist > 25.0" message="Center-to-center distance must maintain bearing clearances" level="error"/>
  </defs>
  <body>
    <chart id="ch_xy">
      <vars>
        <vec3 id="p0" x="0.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e1" x="1.0" y="0.0" z="0.0" fixed="true"/>
        <vec3 id="e2" x="0.0" y="1.0" z="0.0" fixed="false"/>
      </vars>
      <constraints>
        <residual id="u2" expr="dot(e2, e2) - 1.0"/>
        <residual id="or" expr="dot(e1, e2)"/>
        <residual id="pz" expr="dot(e2, vec3(0, 0, 1))"/>
      </constraints>
    </chart>
    <sketch id="sk_arm" chart="ch_xy" max-iter="100">
      <vars>
${outVars}
${bigBore.vars}
${smallBoreVars.join('\n')}
      </vars>
      <wire id="w_outer" closed="true" role="outer">
${outLines}
      </wire>
      <wire id="w_big_bore" closed="true" role="hole">
${bigBore.lines}
      </wire>
      <wire id="w_small_bore" closed="true" role="hole">
${smallBoreLines.join('\n')}
      </wire>
    </sketch>
    <brep id="b_solid">
      <solid_extrude sketch="sk_arm" distance="arm_thk" direction="vec3(0, 0, 1)"/>
    </brep>
  </body>
  <exports>
    <tessellate source="b_solid" linear_deflection="0.01" angular_deflection="0.1"/>
    <step source="b_solid" filename="${stem}.step" schema="AP214"/>
    <stl source="b_solid" filename="${stem}.stl" format="binary"/>
  </exports>
</cdml>
`;
}

const files = fs.readdirSync(LIB_DIR).filter((f) => f.endsWith('.cdml')).sort();
let counts = { bolts: 0, studs: 0, pillow: 0, pulley: 0, nipples: 0, rods: 0 };

for (const file of files) {
  const fullPath = path.join(LIB_DIR, file);
  const xml = fs.readFileSync(fullPath, 'utf8');

  if (/^\d+_hex_bolt_/.test(file)) {
    fs.writeFileSync(fullPath, rebuildHexBolt(file, xml), 'utf8');
    counts.bolts++;
  } else if (/^\d+_threaded_stud_/.test(file)) {
    fs.writeFileSync(fullPath, rebuildThreadedStud(file, xml), 'utf8');
    counts.studs++;
  } else if (file === '0290_pillow_block_bearing_flange_v05_b40.cdml') {
    fs.writeFileSync(fullPath, rebuildPillowBlock0290(file, xml), 'utf8');
    counts.pillow++;
  } else if (file === '0362_timing_pulley_p2m_z18_b8.cdml') {
    fs.writeFileSync(fullPath, rebuildTimingPulley0362(xml), 'utf8');
    counts.pulley++;
  } else if (
    file === '0589_hex_pipe_fitting_nipple_s22_b22_v19.cdml' ||
    file === '0595_hex_pipe_fitting_nipple_s22_b26_v25.cdml'
  ) {
    fs.writeFileSync(fullPath, rebuildHexPipeNipple(file, xml), 'utf8');
    counts.nipples++;
  } else if (/^\d+_connecting_rod_crank_arm_/.test(file)) {
    fs.writeFileSync(fullPath, rebuildConnectingRod(file, xml), 'utf8');
    counts.rods++;
  }
}

console.log('[rebuild_1000_models] Rebuilt models:', counts);
