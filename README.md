# OpenCAD (`open-parametric-cad`)

> **Pure-WASM Parametric CAD Engine, In-Browser Studio & Web Component.**  
> Powered by Zig (WebAssembly), TypeScript & Three.js. Zero native toolchains, zero accounts, zero secret tokens required.

[![Live Studio](https://img.shields.io/badge/Live_Studio-hassaanmaqsood.github.io%2Fopencad-blue?style=for-the-badge&logo=googlechrome)](https://hassaanmaqsood.github.io/opencad/)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-green.svg)](https://opensource.org/licenses/Apache-2.0)
[![Playwright Tests](https://img.shields.io/badge/Playwright-36%2F36_Passed-brightgreen.svg)](https://playwright.dev/)
[![WASM Core: 445 KiB](https://img.shields.io/badge/WASM_Core-445_KiB_Stripped-success.svg)](https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/cad_core.wasm)

---

## 🚀 Instant Launch & Maker Links

| Mode | One-Click Launch URL | Output Formats |
| :--- | :--- | :--- |
| **🌐 Live Studio** | [**Launch OpenCAD Full Studio**](https://hassaanmaqsood.github.io/opencad/) | Full 6 Workbenches + Code-CAD + Git |
| **1️⃣ CNC Bracket** | [**Launch CNC Machined Bracket**](https://hassaanmaqsood.github.io/opencad/?template=template-cnc-bracket) | Analytical B-Rep, 2D GD&T Blueprint, G-Code |
| **2️⃣ Sheet Metal** | [**Launch Electronics Enclosure**](https://hassaanmaqsood.github.io/opencad/?template=template-sheetmetal-enclosure) | Edge Flanges, Miter Reliefs, Unfolded DXF |
| **3️⃣ Flexure Stage** | [**Launch XY Compliant Stage**](https://hassaanmaqsood.github.io/opencad/?template=template-flexure-stage) | Double-Parallelogram, FACT Screw Axes, FEA |
| **4️⃣ Gyroid Mount** | [**Launch Stress-Driven Gyroid Mount**](https://hassaanmaqsood.github.io/opencad/?template=template-aero-gyroid) | FEA Stress Field, TPMS Infill, Production 3MF |

---

## ⚡ Zero-Account Distribution (GitHub Native)

Every OpenCAD distribution channel works directly from GitHub without needing npm, PyPI, or Crates.io tokens.

### 1. HTML `<opencad-viewer>` Web Component (2 Lines)
Embed interactive 3D parametric models with real-time sliders in any HTML page, Notion, or Markdown doc:
```html
<script type="module" src="https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad-element.mjs"></script>
<opencad-viewer template="template-cnc-bracket" sliders="true" height="500px"></opencad-viewer>
```

### 2. Universal ESM CDN Import (1 Line)
```javascript
import { OpenCadCore } from 'https://cdn.jsdelivr.net/gh/hassaanmaqsood/opencad@dist/opencad.mjs';

const cad = await OpenCadCore.create();
const box = cad.createBox(50, 30, 10);
```

### 3. Git-Based Package Installs (Zero External Accounts)
```bash
# Node.js / Bun (ESM + TypeScript types + WASM)
npm install github:hassaanmaqsood/opencad#dist

# Python (Pure-WASM via wasmtime on Desktop / WebAssembly in Pyodide)
pip install "git+https://github.com/hassaanmaqsood/opencad.git@dist#subdirectory=python"

# Rust (Pure-WASM crate with embedded wasm bytes)
cargo add opencad --git https://github.com/hassaanmaqsood/opencad --branch dist
```

### 4. Portable Single-File Offline CAD Studio
Download [**`opencad-portable.html`**](https://hassaanmaqsood.github.io/opencad/opencad-portable.html) and double-click it. It has the WebAssembly kernel and 3D viewport completely inlined—runs anywhere offline with zero internet access.

---

## 📐 The LCM Unified Interface

OpenCAD features a mode-less, friction-free CAD workspace serving Makers, Engineers, Developers, and AI Agents simultaneously without mode switching:

1. **Top-Center Universal Omni-Bar (<kbd>⌘K</kbd> / <kbd>/</kbd> / <kbd>S</kbd>):** Instant CAD tool searches (`extrude`, `fillet`, `thread`, `flange`, `gyroid`), math formula assignments (`width = 120`), slash commands (`/export step`, `/git diff`), and AI agent prompts.
2. **Left "Living Recipe" Dock:** Interactive parameter sliders (slider + formula input), Feature DAG tree with inline scrubbable dimension badges, and synchronized `{ } Code` / `🌿 Git` split dock.
3. **Center 3D/2D Viewport with On-Object HUD:** Floating HUD pill near clicked face/edge with exact editable measurement, Semantic Selector Badge (`>Z`, `@cylindrical`), quick actions, and 3D direct manipulation push/pull gizmo.
4. **Bottom "Lenses & Timeline" Bar:** Composable viewport overlays for `[✂️ Section A-A]`, `[🔥 FEA & Flexure]`, `[📐 Unfold Sheet]`, `[📝 2D Blueprint]`, `[🛠️ 3MF & CAM]`, `[🦓 Zebra]`, plus a continuous `0° - 360°` kinematic motion scrubber and exploded view slider.
5. **Live Telemetry & Global API:** Bottom-right live Code-CAD telemetry echo with 1-click clipboard copy, backed by the unified programmatic `window.opencad` API.

---

## 🛠️ Unified Workbenches

OpenCAD features 6 unified workbenches, with **Bidirectional Code-CAD** and **Git-for-CAD Semantic Versioning** dockable in every mode:

| Workbench | Core Engine | Capabilities |
| :--- | :--- | :--- |
| **📐 Design** | Zig B-Rep & PlaneGCS Solver | 2D sketch constraint solver, parametric solid primitives (Box, Cylinder, Sphere), dress-up fillets/chamfers/shells, and STEP AP214 I/O. |
| **📦 Sheet Metal** | DIN 6935 Sheet Engine | Base tabs, edge flanges with automatic miter trimming, hems, rectangular corner reliefs, and exact 2D flat-pattern unfolding ($BA = \text{angle} \cdot (R + K \cdot T)$). |
| **🔗 Assembly** | 3D Kinematic Mate Solver | Distance, coincident, parallel, and angle mates; high-throughput 60 FPS viewport rendering of 500+ parts using `THREE.InstancedMesh`. |
| **⚡ Simulation & Flexures** | Tet10 PCG Solver & FACT Engine | Isoparametric quadratic `Tet10` meshing, corotational nonlinear FEA, $6\times 6$ spatial compliance matrix $\mathbf{C}$ extraction, and FACT screw-axis synthesis. |
| **🌀 Implicit & Lattices** | SIMD SDF VM & Dual Contouring | Vectorized TPMS minimal surfaces (Gyroid, Schwarz-P, Diamond, Lidinoid, Neovius), FEA field-driven lattice modulation, and sharp-feature QEF Dual Contouring. |
| **⚙️ Manufacturing** | BVH HLR, 3MF Packer & CAM | Analytical Hidden-Line Removal for 2D engineering blueprints, DXF/SVG title-block export, 3D SLS/2D FDM nesting, and 2.5D pocket/contour G-code toolpaths. |

---

## 📦 Standalone Headless SDK & CLI

### CLI Headless Build Tool (`.ocad.ts -> .step / .3mf / .dxf / .gcode`)
```bash
# Build and export all manufacturing outputs in headless CI/CD
npx opencad build bracket.ocad.ts --step --3mf --dxf --gcode --out-dir ./dist
```

### Headless Programmatic Pipeline
```typescript
import { OpenCadCore } from 'opencad';

// 1. Initialize core WASM kernel
const core = await OpenCadCore.create();
const box = core.createBox(50, 40, 20);
```

---

## 🔬 Quick Start & Developer Setup

### 1. Build Native Zig Kernel & WebAssembly Targets
```bash
cd kernel-zig
zig build test               # Asserts 0 memory leaks across 16 test suites
zig build                    # Compiles stripped WASM modules into web-app/public/
```

### 2. Run the Web Application & E2E Tests
```bash
cd web-app
npm install
npm run dev                  # Launch local development server (http://localhost:5173)
npx playwright test          # Run all 36 Playwright E2E browser tests
```

### 3. Assemble Zero-Account Distribution Bundle
```bash
npm run build:dist           # Assembles dist-publish/ for GitHub-only distribution
```

---

## 🏛️ Technical Specifications & Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for deep dives into:
- The zero-copy C ABI memory layout (`CadTessellatedSolidSlice`)
- SIMD Newton-Raphson constraint solving & Shewchuk geometric predicates
- Extension Host & Dynamic WASM/UI Code-Splitting
- Continuous differential fuzzing against OpenCASCADE & PlaneGCS
