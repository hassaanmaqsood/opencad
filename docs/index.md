---
layout: home

hero:
  name: "OpenCAD"
  text: "Merging B-Rep, CSG & Implicit Fields in One Math Core"
  tagline: "Freestanding Zig/WebAssembly parametric CAD kernel, CDML v1.0 executable engineering documents, and zero-copy multi-physics field evaluation."
  image:
    src: /assets/math/hero-math-convergence.svg
    alt: Merging 0b00 B-Rep, 0b01 CSG, and 0b10 Implicit Fields via SSA Tape into One Math Core
  actions:
    - theme: brand
      text: Launch 3D Studio ↗
      link: /studio/
      target: _self
    - theme: alt
      text: Read Documentation →
      link: /guide/

features:
  - title: "0b00 · Exact B-Rep & NURBS"
    details: "Rational B-spline curves, Householder QR rank-revealing 2D sketch solver, and kinematic SE(3) sweeps with analytical dual-number surface normals."
    link: /papers/math-foundations
  - title: "0b01 · Topological CSG & Booleans"
    details: "Shewchuk adaptive exact geometric predicates and Euler–Poincaré manifold invariants (V − E + F = 2) with zero hardcoded primitive meshes."
    link: /guide/architecture
  - title: "0b10 · Implicit SDF & Rvachev C¹ Fields"
    details: "Dual-ring SSA bytecode tape evaluated simultaneously over Dual Numbers (exact ∇F) and Interval Arithmetic (octree pruning) with 0x1F0000 voxel field injection."
    link: /papers/unified-math-article
---

<div class="collab-feature-banner">
  <div class="collab-copy">
    <div class="collab-eyebrow">FEATURED COLLABORATION · MULTI-PHYSICS LOOP</div>
    <h2 class="collab-title">FEAScript × OpenCAD — Closed-Loop Browser FEM</h2>
    <p class="collab-desc">
      Extract 2D domains and rational NURBS boundaries directly from CDML <code>&lt;sketch&gt;</code> documents, solve unstructured triangular PDEs in <strong>FEAScript v0.4.1</strong>, and inject 3D thermal fields back into OpenCAD linear memory at <code>0x1F0000</code>.
    </p>
    <div class="collab-actions">
      <a class="collab-btn-primary" href="/opencad/feascript-demo.html">Launch Live Thermal Demo ↗</a>
      <a class="collab-btn-secondary" href="/opencad/collabs/feascript-thermal-loop">Drop-In ES Modules &amp; Benchmark →</a>
    </div>
  </div>
  <div class="collab-diagram">
    <img src="/assets/math/collab-feascript-loop.svg" alt="FEAScript x OpenCAD Closed-Loop Thermal Architecture" />
  </div>
</div>
