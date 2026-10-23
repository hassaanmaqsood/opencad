# OpenCAD User Guide & Engineering Playbook

OpenCAD is a next-generation open-source parametric CAD system and B-Rep geometric kernel running natively in WebAssembly (WASM), modern WebGL/WebGPU browsers, Node.js, Python, and Rust.

---

## 1. The LCM Unified Interface Architecture

In Wave 14, OpenCAD unifies all previous workbenches and personas into **The LCM Unified Interface**—a mode-less, friction-free CAD workspace where Makers, Engineers, Developers, and AI Agents collaborate simultaneously:

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ 📐 OpenCAD   [  🔍 Search tools, math (w = 120), /commands, AI... (⌘K)  ]   📂 Templates   🚀 │
├─────────────────┬───────────────────────────────────────────────────────────────────────────┤
│ 📋 Living Recipe │                                                                           │
│ ⚙️ Parameters    │                                                                           │
│ width:  [  50 ] │                                                                           │
│ length: [  80 ] │                      Center 3D/2D Viewport                                │
│ ─────────────── │                                                                           │
│ 🌳 Feature DAG  │                           [ >Z  |  20.00 mm ] (On-Object HUD)             │
│ ✏️ Sketch 1 20mm│                              ⬆️ Extrude  🕳️ Hole  🔩 Thread                │
│ 📦 Extrude 1 80m│                                                                           │
│ 🪚 Fillet 1 6mm │                                                                           │
│ ─────────────── │                                                                           │
│ { } Code  🌿 Git│                                                                           │
├─────────────────┴───────────────────────────────────────────────────────────────────────────┤
│ Lenses: [✂️ Section A-A] [🔥 FEA] [📐 Unfold] [📝 Blueprint] [🛠️ CAM]   ▶ Motion: [───] 0°  │
│                                            ⚡ part.faces(">Z").extrude(20.0); [📋 Copy]      │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Top-Center Universal Omni-Bar (<kbd>⌘K</kbd> / <kbd>/</kbd> / <kbd>S</kbd>)
- **Tool Search:** Instant autocompletion for all CAD operations (`extrude`, `revolve`, `fillet`, `chamfer`, `hole wizard`, `thread`, `flange`, `gyroid`, `mate`, `datum`).
- **Mathematical Parameter Assignment:** Type `length = 120` or `width = 25 * 2` directly in the bar to update parametric variables and model dimensions on the fly.
- **Slash Commands:** One-touch commands like `/export step`, `/export 3mf`, `/export dxf`, `/git diff`, `/screenshot`, and `/inspect zebra`.
- **AI Agent Prompts:** Type natural language briefs (e.g. `create a parametric box with filleted edges`) to execute autonomous agent modeling.

### 1.2 Left "Living Recipe" Dock
- **Parameter Sliders:** Combines smooth scrubbable range sliders with editable formula/number text inputs (`data-testid="param-input-${name}"`).
- **Feature & Assembly DAG Tree:** Inline scrubbable dimension badges (`data-testid="scrub-badge-${id}"`) with one-click click-to-edit input.
- **Dockable Toggles:** Instant `{ } Code` and `🌿 Git` split dock toggles (<kbd>Ctrl+`</kbd>).

### 1.3 Center 3D/2D Viewport with On-Object Contextual HUD
- **Floating HUD Pill:** Appears near clicked face or edge with exact dimension input and Semantic Selector Badge (`>Z`, `@cylindrical`, `|Z`).
- **3D Direct Manipulation Arrow Gizmo:** Rendered in Three.js aligned with the face normal vector for interactive push/pull dimension dragging.
- **Context-Smart Quick Actions:** Face clicks show `Sketch`, `Extrude`, `Hole`, `Thread`, and `Datum`. Edge clicks show `Fillet`, `Chamfer`, and `Flange`.

### 1.4 Bottom "Lenses & Timeline" Bar
Replaces isolated workbench rooms with composable viewport lenses:
- `[✂️ Section A-A]`: Interactive 3D section plane with hatched cap surfaces.
- `[🔥 FEA & Flexure]`: Real-time Von Mises stress colormap shader and FACT flexure compliance overlays.
- `[📐 Unfold Sheet]`: In-situ DIN 6935 2D flat-pattern projection.
- `[📝 2D Blueprint]`: Synchronized associative orthographic engineering drawings.
- `[🛠️ 3MF & CAM]`: 3MF production nesting bounds and subtractive CNC toolpath overlays.
- `[🦓 Zebra]`: Surface curvature continuity stripe inspection.
- **Kinematic Scrubber:** Continuous `0° - 360°` interactive joint motion scrubber with animated play/pause (`▶ / ⏸`) and Exploded View slider.

### 1.5 Live Command Telemetry Bar & `window.opencad` API
- **Telemetry Bar:** Echoes every GUI click and modification as an equivalent one-line Code-CAD command (e.g. `part.faces(">Z").holeWizard("M6", "counterbore");`) with one-click clipboard copy.
- **Headless / Agent API (`window.opencad`):** Full programmatically callable interface:
  ```ts
  await window.opencad.runCommand('createBox', { dimensions: [3, 3, 3] });
  window.opencad.select('>Z');
  const diag = await window.opencad.getDiagnostics();
  const ast = window.opencad.getRecipeAST();
  const views = await window.opencad.captureOrthographicViews();
  await window.opencad.exportStep();
  ```

---

## 2. 2D & 3D Sketching Engine

### 2.1 2D Sketch Entities & Constraints
- **Entities:** Line, Rectangle, Circle, Center Arc, **Cubic / NURBS Spline**, **Slot / Stadium**, **Ellipse**, **Regular Polygon**, and **Vector Text**.
- **Construction Geometry:** Press <kbd>Q</kbd> to toggle any entity or selection between driving solid geometry and dashed reference construction geometry.
- **Geometric Constraints:** Coincident, Horizontal, Vertical, Parallel, Perpendicular, Tangent, Equal Length/Radius, Symmetric, Distance/Dimension, Angle, and Radius.

### 2.2 2D Sketch Modifiers & Booleans
- **2D Fillet & Chamfer:** Corner rounding and beveling directly in the 2D sketch loop.
- **Offset Wire:** Parallel curve expansion and contraction.
- **Trim Curve:** Click-to-cut curve segments against intersections.
- **Planar Region Extraction:** Shaded region detection powered by planar half-edge arrangements and Shoelace area integration.

### 2.3 3D Sketching
The native 3D sketch solver solves non-planar coordinate loops with 3D distance, along-axis, and on-plane constraints for complex 3D wire routing, frame design, and sweep paths.

---

## 3. Workbenches

### 3.1 Design (B-Rep & Primitives)
- Precision analytical solids: Box, Cylinder, Sphere, Torus, Cone.
- Operations: Extrude, Revolve, Sweep, Loft with $G_0, G_1, G_2$ continuity.
- Dress-up: Variable-radius Fillet, Chamfer, Thin-wall Shell.
- Booleans: Union, Difference, Intersection with topological naming preservation.

### 3.2 Sheet Metal
- Sheet metal tabs, bends, flanges, hems, and K-factor unfolding.
- Real-time 2D flat pattern generation exported directly to DXF with bend lines and tooling callouts.

### 3.3 Kinematic Assembly
- High-performance multi-body assembly solver handling >500 instances at a steady 60 FPS.
- Kinematic mate types: Coincident, Concentric, Parallel, Distance, Angle, **Gear Coupler**, **Rack & Pinion**, **Lead Screw**, and **Cam Follower**.
- Interactive exploded view with automatic 3D guideline trail generation.

### 3.4 Simulation & Flexures (FEA & FACT)
- Tet4/Tet10 Delaunay tetrahedral meshing.
- Linear and corotational PCG elastic solver producing Von Mises stress and deformation fields.
- Freedom and Constraint Topologies (FACT) compliant flexure synthesis and $6 \times 6$ spatial compliance matrix extraction.

### 3.5 Implicit & Lattices (nTop-Style)
- Vectorized SIMD byte-code SDF evaluators with interval arithmetic.
- Triply Periodic Minimal Surfaces (TPMS): Gyroid, Schwarz-P, Schwarz-D, Lidinoid, Neovius.
- Strut-lattice graphs: BCC, FCC, Octet-Truss.
- Stress-field-driven lattice modulation scaling wall thickness from low-stress to high-stress zones.

### 3.6 Manufacturing (2D Drawings, 3MF Nesting & CNC CAM)
- Exact B-Rep Hidden-Line Removal (HLR) projection with ANSI/ISO drawing sheets.
- Cross-section slicing with automatic $45^\circ$ hatching, auxiliary views, and detail callouts.
- 2D irregular shape nesting for laser cutting.
- 2.5D/3D CNC milling toolpath generation with customizable feeds, speeds, and post-processed G-code.

---

## 4. Keyboard Shortcuts & Gestures

| Shortcut | Action |
| :--- | :--- |
| <kbd>S</kbd> | Open circular Radial Pie Menu at cursor (Extrude, Revolve, Fillet, Chamfer, Hole, Sketch, Section) |
| <kbd>Q</kbd> | Toggle Construction reference mode in Sketcher |
| <kbd>Escape</kbd> | Dismiss radial menu, cancel current sketch tool, or deselect |
| <kbd>Space</kbd> | Center viewport on current selection |
| <kbd>L</kbd> | Cycle Level of Detail (Coarse, Medium, Fine) |
