# OpenCAD Python — Pure-WASM Parametric CAD Kernel

Zero-dependency, cross-platform Python bindings for OpenCAD. Powered by pure WebAssembly (`wasmtime` on desktop/server, Pyodide in-browser), requiring **zero C++ compilers, zero shared libraries, and zero pre-built wheels**.

## Installation

Install directly from GitHub with zero accounts or tokens:

```bash
pip install "git+https://github.com/hassaanmaqsood/opencad.git@dist#subdirectory=python"
```

## Quickstart

```python
from opencad import sketch, XY, box, cylinder, export_step, show

# 1. Direct 3D Parametric Primitives
bracket = box(50.0, 30.0, 10.0)
hole = cylinder(radius=3.5, height=12.0)

# 2. 2D Sketching & Extrusion
profile = (
    sketch(XY)
    .circle(0, 0, 15.0)
    .rect(-5, -5, 10, 10)
    .extrude(height=25.0)
)

# 3. Export to ISO-10303-21 AP214 STEP for CNC/3D Printing
export_step(profile, "output.step")

# 4. Display in Jupyter or browser
show(profile)
```

## Features
- **Pure WebAssembly:** Runs identically on Linux, macOS, Windows, ARM64, Raspberry Pi, and inside in-browser Pyodide notebooks (JupyterLite / Google Colab).
- **Geometric Constraint Solver:** Exact 2D/3D degrees-of-freedom reduction.
- **Manufacturing Pipelines:** STEP AP214, 3MF production packages, DXF 2D blueprints, and Fanuc/Grbl G-code export.
- **Advanced Mechanics:** FACT compliant flexure synthesis and corotational nonlinear FEA.
