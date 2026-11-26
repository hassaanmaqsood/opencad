# OpenCAD User Guide

OpenCAD is an open-source parametric 3D CAD application and geometric kernel. It runs in web browsers through WebAssembly and WebGL.

## 1. Application Layout

The OpenCAD Studio interface uses a split workspace for parametric modeling:

```text
┌────────────────────────────────────────┬────────────────────────────────────────┐
│ CDML Code Editor                       │ 3D CAD Viewport                        │
│ (CodeMirror 6 · Surface #F7F7F8)       │ (Three.js WebGL · Paper #FFFFFF)       │
│                                        │  ┌────┐                         ┌────┐ │
│ <cdml version="1.0" units="mm">        │  │Dock│                         │GUI │ │
│   <defs>                               │  └────┘                         └────┘ │
│     <var id="R" value="24.0" />        │                                        │
│   </defs>                              │                                        │
│ </cdml>                                │                         Telemetry HUD  │
├────────────────────────────────────────┴────────────────────────────────────────┤
│ Status Dot  |  Status Message / Diagnostics  |  Reset  |  Eval Time (ms)        │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Code Editor Panel (Left)
- **Syntax Highlighting:** The editor uses CodeMirror 6 with XML syntax highlighting in the OpenCAD light paper theme (`IBM Plex Mono` and Cobalt Azure `#0C71E4` accents).
- **Line Wrapping:** Long lines wrap inside the editor pane without horizontal scrollbars.
- **Automatic Evaluation:** Code changes run the WebAssembly kernel automatically after a 200 ms debounce delay.
- **Collapse Toggle:** Click the `</>` button in the left viewport dock to hide or show the code editor.

### 1.2 3D Viewport & Left Floating Dock (Right)
- **Orbit Camera:** Drag the left mouse button to rotate the camera around the solid.
- **Pan Camera:** Drag the right mouse button to move the camera parallel to the view plane.
- **Zoom Camera:** Roll the mouse wheel to zoom toward or away from the model.
- **Left Floating Action Dock:**
  - **Code Toggle (`</>`):** Shows or hides the CDML code editor pane.
  - **Screenshot:** Captures a PNG image of the 3D canvas.
  - **Fit View:** Centers and scales the camera to fit the active solid bounding box.
  - **Wireframe Toggle:** Toggles the triangle mesh edge overlay on the solid.
  - **Parameters Toggle:** Shows or hides the `Model Parameters` inspector tray.

### 1.3 Reactive Parameters Panel (Top-Right)
- The studio builds input sliders for all public `<var>` elements in the CDML document.
- Dragging a slider updates the variable through `cdml_set_var` and re-evaluates the 3D mesh in real time.
- Private variables (prefixed with `_` or marked `private="true"`) do not appear in the panel.

### 1.4 Status Bar and Diagnostic Drawer
- **Status Dot:** Shows charcoal (`#18181B`) when valid, soft azure (`#5AA9FF`) while evaluating, and deep cobalt (`#0A50A8`) when an error occurs.
- **Status Message:** Shows the evaluation status, active notices, and kernel execution time in milliseconds.
- **Diagnostic Drawer:** Click the status message or the `Details` button when an error occurs to open the diagnostic drawer.
- The diagnostic drawer lists the error code, line number, column number, XML tag name, and diagnostic message.

## 2. CDML v1.0 Modeling Workflow

Every CDML v1.0 document follows a 4-step structure inside `<cdml version="1.0" units="mm">`.

### Step 1: Define Variables and Assertions (`<defs>`)
Define parametric variables, derived expressions, and safety assertions inside `<defs>`:

```xml
<defs>
  <var id="flange_w" value="90.0" min="60.0" max="150.0" unit="mm" public="true"/>
  <var id="flange_h" value="16.0" min="8.0"  max="40.0"  unit="mm" public="true"/>
  <var id="bore_r"   value="15.0" min="8.0"  max="25.0"  unit="mm" public="true"/>
  <expr id="half_w"  expr="ref(flange_w) / 2"/>
  <assert id="bore_clearance"
    expr="ref(half_w) - ref(bore_r) - 5.0"
    error="bore radius exceeds flange margin"/>
</defs>
```

### Step 2: Define a Coordinate Chart (`<body> > <chart>`)
Define an orthonormal coordinate frame in 3D space inside `<body>`:

```xml
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
```

### Step 3: Build a 2D Constrained Sketch (`<body> > <sketch>`)
Define 2D control points, outer and hole `<wire>` loops (using `<curve>` or `<param-curve>`), and residual equations:

```xml
<sketch id="sk_flange" chart="chart_xy" max-iter="100">
  <vars>
    <point2d id="v0" u="-45.0" v="-45.0"/>
    <point2d id="v1" u=" 45.0" v="-45.0"/>
    <point2d id="v2" u=" 45.0" v=" 45.0"/>
    <point2d id="v3" u="-45.0" v=" 45.0"/>
  </vars>
  <wire id="wire_outer" closed="true" role="outer">
    <curve id="s0" degree="1" ctrl="v0 v1" weights="1.0 1.0" knots="0 0 1 1"/>
    <curve id="s1" degree="1" ctrl="v1 v2" weights="1.0 1.0" knots="0 0 1 1"/>
    <curve id="s2" degree="1" ctrl="v2 v3" weights="1.0 1.0" knots="0 0 1 1"/>
    <curve id="s3" degree="1" ctrl="v3 v0" weights="1.0 1.0" knots="0 0 1 1"/>
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
```

### Step 4: Sweep into a 3D Solid, Probe, and Export (`<brep>`, `<probe>`, `<exports>`)
Sweep the solved sketch profile along an $SE(3)$ trajectory, attach physical probes, and declare exports:

```xml
<brep id="solid_flange">
  <sweep id="sw_extrude" sketch="sk_flange" cap-ends="true">
    <trajectory>
      <translate x="0" y="0" z-expr="ref(flange_h) * v"/>
    </trajectory>
  </sweep>
</brep>

<probe id="housing_volume" type="volume" target="solid_flange"/>
```

```xml
<exports>
  <tessellate target="solid_flange" chord-tol="0.02" angle-tol="0.05"/>
  <step       target="solid_flange" schema="AP214"/>
  <stl        target="solid_flange" binary="true"/>
</exports>
```

## 3. Web Page Embedding

You can embed the 3D CAD viewer into documentation pages or web applications.

### 3.1 Embed via Iframe and URL Parameters
Point an `<iframe>` to `/opencad/studio/` (or `/opencad/`, which forwards Studio query parameters automatically) with `?embed=true`:

```html
<iframe
  src="https://hassaanmaqsood.github.io/opencad/studio/?embed=true&src=/opencad/examples/flange_normative.cdml&gui=true"
  width="100%"
  height="500"
  style="border: 0; border-radius: 8px;"
  loading="lazy"
  title="OpenCAD 3D Viewer">
</iframe>
```

Supported URL query parameters:
- `embed`: Set to `true` to hide the code editor and render a full-bleed 3D viewport.
- `src` or `cdml`: URL, relative path (such as `/opencad/examples/flange_normative.cdml`), or inline XML string.
- `gui` or `params`: Set to `true` or `false` to show or hide the parameter slider panel.
- `code-toggle`: Set to `false` to hide the code editor toggle button in the left dock.
- `params-toggle`: Set to `false` to hide the parameters toggle button in the left dock.
- `vars`: Comma-separated list of variable IDs to show in the slider panel.
- `probes`: Comma-separated list of physical probe IDs to show in the panel.
- `exports`: Comma-separated list of export buttons (`step,stl`).

### 3.2 Embed via Custom HTML Element (`<opencad-viewer>`)
Load the web component from the distribution CDN and point `src` to a valid `.cdml` file:

```html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>

<opencad-viewer
  src="https://raw.githubusercontent.com/hassaanmaqsood/opencad/main/examples/constrained_bracket.cdml"
  data-gui="true"
  style="width: 100%; height: 500px; display: block;">
</opencad-viewer>
```

## 4. Mouse and Keyboard Controls

| Input | Action |
| :--- | :--- |
| <kbd>Mouse Left Drag</kbd> | Rotate the 3D camera around the target center. |
| <kbd>Mouse Right Drag</kbd> | Pan the 3D camera parallel to the screen plane. |
| <kbd>Mouse Wheel</kbd> | Zoom the 3D camera toward or away from the model. |
