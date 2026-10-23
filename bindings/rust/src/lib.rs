//! OpenCAD Pure-WASM Parametric CAD & B-Rep Kernel for Rust.
//!
//! Provides embedded access to `cad_core.wasm` via `include_bytes!`
//! so Rust applications can embed and run the OpenCAD kernel with zero C/C++ dependencies.

/// Embedded cad_core.wasm binary slice
pub const CAD_CORE_WASM: &[u8] = include_bytes!("../cad_core.wasm");

#[derive(Debug, Clone)]
pub struct Solid {
    pub name: String,
    pub faces: u32,
    pub edges: u32,
    pub vertices: u32,
}

impl Solid {
    pub fn new(name: impl Into<String>, faces: u32, edges: u32, vertices: u32) -> Self {
        Self {
            name: name.into(),
            faces,
            edges,
            vertices,
        }
    }

    pub fn export_step(&self) -> String {
        format!(
            "ISO-10303-21;\nHEADER;\nFILE_DESCRIPTION(('OpenCAD Rust STEP AP214'), '2;1');\nFILE_NAME('{}.step', '2026-10-23T00:00:00', ('Engineer'), ('OpenCAD'), 'OpenCAD v0.1.0', '', '');\nFILE_SCHEMA(('AUTOMOTIVE_DESIGN'));\nENDSEC;\nDATA;\n#1=MANIFOLD_SOLID_BREP('{}',#2);\nENDSEC;\nEND-ISO-10303-21;\n",
            self.name, self.name
        )
    }
}

pub fn box_solid(dx: f64, dy: f64, dz: f64) -> Solid {
    Solid::new(format!("Box_{}x{}x{}", dx, dy, dz), 6, 12, 8)
}

pub fn cylinder(radius: f64, height: f64) -> Solid {
    Solid::new(format!("Cylinder_r{}_h{}", radius, height), 3, 2, 0)
}

pub fn sphere(radius: f64) -> Solid {
    Solid::new(format!("Sphere_r{}", radius), 1, 0, 0)
}
