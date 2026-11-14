# OpenCAD Rust — Pure-WASM Parametric CAD Kernel

Zero-dependency, cross-platform Rust bindings for OpenCAD with embedded `cad_core.wasm`.

## Installation

Add directly from GitHub without Crates.io accounts:

```bash
cargo add opencad --git https://github.com/hassaanmaqsood/opencad --branch dist
```

Or in `Cargo.toml`:

```toml
[dependencies]
opencad = { git = "https://github.com/hassaanmaqsood/opencad", branch = "dist" }
```

## Quickstart

```rust
use opencad::{box_solid, cylinder, CAD_CORE_WASM};

fn main() {
    // 1. Inspect embedded WebAssembly binary bytes
    println!("Loaded OpenCAD WASM ({} bytes)", CAD_CORE_WASM.len());

    // 2. Generate 3D Parametric Primitives
    let bracket = box_solid(50.0, 30.0, 10.0);
    println!("Generated: {:?}", bracket);

    // 3. Export ISO-10303-21 STEP
    let step_text = bracket.export_step();
    println!("STEP text:\n{}", step_text);
}
```
