# OpenCAD User Guide

OpenCAD is an open-source parametric 3D CAD application and geometric kernel. It runs in modern web browsers using WebAssembly and WebGL.

---

## 1. Application Layout

The OpenCAD browser interface provides a split workspace for parametric modeling:

```
┌────────────────────────────────────────┬────────────────────────────────────────┐
│ CDML Code Editor                       │ 3D CAD Viewport                        │
│ (CodeMirror 6)                         │ (Three.js WebGL)                       │
│                                        │                                        │
│ <cdml version="1.0" units="mm">        │                                        │
│   <defs>                               │                                        │
│     <var id="radius" value="25.0" />   │                                        │
│   </defs>                              │                                        │
│   ...                                  │                                        │
│ </cdml>                                │                                        │
├────────────────────────────────────────┴────────────────────────────────────────┤
│ Status Dot  |  Status Message / Diagnostics  |  Dimensions  |  Triangles  | FPS │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Code Editor Panel (Left)
- **Syntax Highlighting:** The editor uses CodeMirror 6 with XML syntax highlighting and OneDark theme.
- **Line Wrapping:** Text wraps within the editor pane without horizontal scrollbars.
- **Automatic Synchronization:** Edits automatically trigger kernel evaluation after 200 milliseconds.
- **Collapse Toggle:** Click the collapse button on the splitter to hide the editor for full-screen 3D viewing.

### 1.2 3D Viewport (Right)
- **Orbit Navigation:** Drag the left mouse button to rotate the camera around the solid.
- **Pan Navigation:** Drag the right mouse button to move the camera horizontally and vertically.
- **Zoom Navigation:** Roll the mouse wheel to zoom toward or away from the model.
- **Fit View:** Click the camera icon in the top-right toolbar to frame the entire model in the center.
- **Wireframe Toggle:** Click the wireframe icon to switch between shaded faces and edge wireframes.
- **Screenshot:** Click the camera screenshot icon to save a high-resolution PNG image of the current view.

### 1.3 Reactive Parameters Panel
- The interface automatically generates input sliders for all public `<var>` elements defined in the CDML document.
- Moving a slider re-evaluates the kernel in real time without reloading the page.
- Private variables (prefixed with an underscore or marked `private="true"`) remain hidden from the panel.

### 1.4 Status Bar and Diagnostic Drawer
- **Status Dot:** Shows green for nominal evaluations, yellow for processing, and red for syntax or topological errors.
- **Status Message:** Displays execution time in milliseconds and model diagnostic codes.
- **Diagnostic Drawer:** Click the status text or details button when an error occurs to open the diagnostic drawer.
- The drawer displays the line number, column number, XML tag name, and error message.

---

## 2. CDML Modeling Workflow

OpenCAD models follow a structured 4-step workflow:

### Step 1: Define Variables and Constants
Define parametric dimensions inside the `<defs>` container:

```xml
<defs>
  <var id="length" value="100.0" min="50.0" max="200.0" unit="mm" />
  <var id="width" value="60.0" min="30.0" max="120.0" unit="mm" />
  <var id="height" value="20.0" unit="mm" />
</defs>
```

### Step 2: Establish Coordinate Charts
Establish local orthonormal coordinate frames for sketch placement:

```xml
<charts>
  <chart id="base_plane" type="orthonormal">
    <origin x="0.0" y="0.0" z="0.0" />
    <axis_u x="1.0" y="0.0" z="0.0" />
    <axis_v x="0.0" y="1.0" z="0.0" />
    <axis_w x="0.0" y="0.0" z="1.0" />
  </chart>
</charts>
```

### Step 3: Draw 2D Sketches
Draw closed wire profiles with outer boundaries and inner cutout holes:

```xml
<sketches>
  <sketch id="profile" chart="base_plane">
    <!-- Outer rectangle boundary -->
    <rect_wire id="outer_boundary" width="ref(length)" height="ref(width)" role="outer" />
    <!-- Inner circular hole -->
    <circle_wire id="mounting_hole" cx="0.0" cy="0.0" radius="10.0" role="hole" />
  </sketch>
</sketches>
```

### Step 4: Generate Solids and Exports
Sweep the 2D sketch into a 3D solid and specify manufacturing exports:

```xml
<breps>
  <brep id="main_body">
    <sweep_extrude id="extrude_op" sketch="profile" z_expr="ref(height) * v" />
  </brep>
</breps>

<exports>
  <tessellate solid="main_body" chordal_tol="0.01" angular_tol="0.05" />
  <step solid="main_body" />
  <stl solid="main_body" binary="true" />
</exports>
```

---

## 3. Web Page Embedding

You can embed the 3D CAD viewer into documentation, web applications, or blogs.

### 3.1 Embed via URL Parameters
Add `?embed=true` to the application URL to enter minimal viewer mode:

```
https://hassaanmaqsood.github.io/opencad/?embed=true&src=models/bracket.cdml&gui=true
```

Available URL parameters:
- `embed`: Set to `true` to hide the code editor and header.
- `src` or `cdml`: Specifies the URL of the CDML document to load.
- `gui`: Set to `false` to hide the parameter slider panel.
- `vars`: Comma-separated list of variable IDs to expose in the slider panel.
- `exports`: Comma-separated list of export formats (`step`, `stl`).

### 3.2 Embed via Custom HTML Element
Load the web component from the distribution CDN:

```html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>

<opencad-viewer
  src="https://raw.githubusercontent.com/hassaanmaqsood/opencad/main/examples/lib/0001_bracket.cdml"
  data-gui="true"
  style="width: 100%; height: 500px; display: block;">
</opencad-viewer>
```

---

## 4. Keyboard Shortcuts

| Shortcut | Description |
| :--- | :--- |
| <kbd>Ctrl</kbd> + <kbd>S</kbd> | Evaluates the current CDML document immediately. |
| <kbd>Mouse Left Drag</kbd> | Rotates the 3D camera around the model. |
| <kbd>Mouse Right Drag</kbd> | Pans the camera across the view plane. |
| <kbd>Mouse Wheel</kbd> | Zooms the camera into or out of the scene. |
