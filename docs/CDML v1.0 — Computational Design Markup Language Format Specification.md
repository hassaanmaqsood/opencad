# CDML v1.0 — Computational Design Markup Language

Oct 30, 2026 · @Hassaan Maqsood

## 1. Scope and Design Laws

CDML is a human-readable, machine-executable XML format for parametric geometry. It covers three representation tiers — Boundary Representation (B-Rep), Constructive Solid Geometry (CSG), and Implicit/Field geometry — unified by a single math kernel.

### 1.1 What this format is

- A declarative description of geometry as equations and constraint systems
- A stable interchange format between authoring tools, kernels, and simulation extensions
- A document a human can write, read, diff, and version-control
- A document a language model can generate, parse, and reason about

### 1.2 What this format is not

- **Not a kernel implementation spec.** Memory layout, arena allocation, and WASM ABI are Kernel Reference concerns. The XML format defines the interface contract only.
- **Not a mesh format.** CDML describes exact geometry. Tessellation is a kernel export operation.
- **Not a scene graph.** Composition is handled by `<compose>` but CDML is not a scene graph language.

### 1.3 Normative Design Laws

**Zero-Primitive Mandate.** No predefined shape tags exist. Every geometric entity is defined through algebraic equations `f(x,y,z) = 0`, parametric trajectories `r(t)`, SE(3) kinematic sweeps, or scalar field inequalities `F(x,y,z) ≤ 0`. The words `cylinder`, `box`, `sphere`, `torus`, `gyroid` never appear as element tags.

**Equation-First.** All numeric attributes accept a literal value, a `ref="id"` to a declared variable, or an `expr="..."` inline expression. The math kernel evaluates all three uniformly.

**Exact Gradients.** All expressions compile to an SSA bytecode tape evaluated over forward-mode dual numbers `ℝ[ε]/(ε²=0)`. Exact analytical partial derivatives are always available. No finite differences.

**Stable Topology.** Every topological entity carries a deterministic 192-bit `TopoId` that survives upstream parameter recomputation. XML `id` attributes name document elements; `TopoId` names geometric sub-shapes. These are separate namespaces.

**Manifold Guarantee.** Every solid must satisfy `V - E + F - (L - F) - 2(S - G) = 0`. The kernel validates after every operation and rejects non-manifold results.

**Separation of Concerns.** The XML format describes *what* the geometry is. The Kernel Reference describes *how* it evaluates. Runtime memory layout and WASM lifecycle hooks do not appear in this document.

## 2. Document Structure

A CDML document is rooted at `<cdml>` and divided into four ordered sections: `<imports>`, `<defs>`, `<body>`, and `<exports>`. Parsers must process sections in this order. `<imports>` is optional and resolved first; its effect is to merge external definitions into the current document's namespace before `<defs>` is evaluated.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0"
      units="mm"
      linear_tol="1e-7"
      angular_tol="1e-11">

  <imports>  <!-- resolved at parse time; optional -->
    ...
  </imports>

  <defs>     <!-- variables, expressions, materials, field slots -->
    ...
  </defs>

  <body>     <!-- geometry tree -->
    ...
  </body>

  <exports>  <!-- tessellation and file output targets -->
    ...
  </exports>

</cdml>
```

### 2.1 Root attributes

| Attribute | Type | Default | Description |
| --- | --- | --- | --- |
| `version` | string | required | Must be `"1.0"`. Parsers reject mismatches with `ERR_SCHEMA_VERSION`. |
| `units` | enum | `"mm"` | Base length unit: `mm`, `m`, `in`, `um`. All internal solver coordinates normalise to millimetres. |
| `linear_tol` | float | `1e-7` | Euclidean coincidence tolerance εₗᵢₙ in mm. |
| `angular_tol` | float | `1e-11` | Angular cosine tolerance εₐₙg in radians. |

### 2.2 Numeric attribute contract

Every attribute that accepts a number obeys this contract uniformly:

- **Literal:** `radius="25.0"` — parsed as a 64-bit float.
- **Reference:** `radius-ref="R"` — resolved to the value of `<var id="R">` at evaluation time.
- **Expression:** `radius-expr="R - t"` — compiled to SSA bytecode and evaluated by the math kernel.

The `-ref` and `-expr` suffix convention applies to any base attribute name. A `<var>` that has not been declared is a parse error `ERR_UNDEFINED_REF`. Expression evaluation errors propagate as `ERR_EXPR_DIV_ZERO` or `ERR_EXPR_NAN_INF` with the offending expression id and variable values included in the diagnostic payload.

## 2a. Imports

`<imports>` resolves external CDML files at parse time. The effect is to merge the imported document's `<defs>` (variables, expressions, materials, field slots, named geometry) into the current document's namespace under an optional prefix. It is a parse-level operation — the kernel never sees an unresolved import.

```xml
<imports>

  <!-- Merge all defs from a standard parts library.
       Items become: fasteners.bolt_d, fasteners.bolt_pcd, etc. -->
  <import src="lib/fasteners.cdml" prefix="fasteners"/>

  <!-- Merge material library with no prefix — names enter directly.
       Conflicts with local defs are rejected as ERR_IMPORT_CONFLICT. -->
  <import src="lib/materials.cdml"/>

  <!-- Import selected named geometry from another file.
       The ids wire_bore and solid_flange enter as bh.wire_bore, bh.solid_flange. -->
  <import src="parts/bearing_housing.cdml"
          prefix="bh"
          select="solid_flange wire_bore"/>

</imports>
```

### 2a.1 Import resolution rules

**Parse order.** Imports are resolved depth-first in document order. The merged namespace is available to all subsequent `<defs>` and `<body>` elements. Imports within imported files are resolved recursively.

**Prefix.** If `prefix="p"` is given, every imported `id` is rewritten to `p.id` in the current namespace. `ref(p.R)` and `from_id('p.c_bore')` resolve against the prefixed names. Without a prefix, names enter directly.

**Select.** If `select="id1 id2 ..."` is given, only the listed element `id`s and their transitive `<defs>` dependencies are merged. Without `select`, all `<defs>` are merged. Named geometry (`<brep>`, `<implicit>`, `<csg>`, `<sketch>`) is only imported when explicitly listed in `select=`.

**Conflict.** A name collision between an imported id and a locally declared id is rejected with `ERR_IMPORT_CONFLICT`, identifying both elements. Prefixes are the canonical tool for avoiding collisions.

**Immutability.** Imported elements are read-only. To override an imported parameter, declare a new local name and reference it in a local `<expr>`.

**No circular imports.** The import DAG must be acyclic. A cycle is rejected at parse time with `ERR_DAG_CYCLE`.

**No runtime imports.** `src=` is a static path resolved relative to the document's location at parse time.

### 2a.2 What can be imported

| Category | From `<defs>` | From `<body>` via `select=` |
| --- | --- | --- |
| `<var>`, `<expr>`, `<assert>`, `<material>` | Always, unless filtered | — |
| `<field-slot>` | Always, unless filtered | — |
| `<chart>`, `<sketch>` | Only when listed in `select=` | Only when listed |
| `<brep>`, `<implicit>`, `<csg>` | — | Only when listed |

Importing a `<brep>` or `<implicit>` that reads a `<field-slot>` also imports that slot declaration, preserving the `field_scalar()` binding.

## 3. Math Kernel

The math kernel is the single evaluation engine behind all `expr=` attributes. It operates over two algebraic rings simultaneously.

### 3.1 Dual-number autodiff

For any expression `F(x)`, the kernel evaluates over forward-mode dual numbers `ℝ[ε]/(ε²=0)`. Substituting `xᵢ → xᵢ + 1·ε` yields the exact primal value `F(x)` and the exact partial derivative `∂F/∂xᵢ` in one pass — no finite differences, zero truncation error. This is used for Newton-Raphson sketch solving, QEF dual contouring vertex placement, and future simulation coupling.

### 3.2 Interval arithmetic

For any axis-aligned bounding box `[x_min,x_max] × [y_min,y_max] × [z_min,z_max]`, the kernel evaluates `F` over interval arithmetic `ℝ` to produce guaranteed bounds `[F_min, F_max]`. If `F_min > τ` or `F_max < -τ`, the octree cell is pruned in O(1) time. This drives adaptive subdivision for implicit solid tessellation.

### 3.3 SSA bytecode instruction set

All `expr=` strings compile to a Static Single Assignment (SSA) bytecode tape via `expr_compile()`. The tape is the canonical form; the XML string is only the source representation.

| Opcode | Mnemonic | Primal | Dual derivative |
| --- | --- | --- | --- |
| 0x01 | CONST | c | 0 |
| 0x02 | VAR | xᵢ | δᵢⱼ |
| 0x10 | ADD | u + v | du + dv |
| 0x11 | SUB | u − v | du − dv |
| 0x12 | MUL | u · v | v·du + u·dv |
| 0x13 | DIV | u / v | (v·du − u·dv) / v² |
| 0x14 | POW | uᵛ | uᵛ⁻¹(v·du + u·ln(u)·dv) |
| 0x20 | SIN | sin(u) | cos(u)·du |
| 0x21 | COS | cos(u) | −sin(u)·du |
| 0x22 | EXP | eᵘ | eᵘ·du |
| 0x23 | LOG | ln(u) | du/u |
| 0x24 | SQRT | √u | du/(2√u) |
| 0x25 | ABS\_SMOOTH | √(u²+ε²) | u·du/√(u²+ε²) |
| 0x26 | ABS | \|u\| | sign(u)·du  (0 at u = 0) |
| 0x30 | R\_UNION | u+v−√(u²+v²) | du(1−u/√(u²+v²)) + dv(1−v/√(u²+v²)) |
| 0x31 | R\_INTERSECT | u+v+√(u²+v²) | du(1+u/√(u²+v²)) + dv(1+v/√(u²+v²)) |
| 0x32 | LT | 1.0 if u < v else 0.0 | 0 |
| 0x33 | GT | 1.0 if u > v else 0.0 | 0 |
| 0x34 | AND | 1.0 if u ≠ 0 and v ≠ 0 else 0.0 | 0 |
| 0x35 | OR | 1.0 if u ≠ 0 or v ≠ 0 else 0.0 | 0 |
| 0x40 | FIELD\_SAMPLE | Φᵢd(x,y,z) | trilinear B-spline gradient ∇Φ |
| 0x41 | PROBE | cached result of probe (immediate = probe index) | 0  (constant within one evaluation pass) |
| 0x42 | FROM\_ID | 1.0 if the sub-shape's TopoId matches the immediate H64 value (§10.1.1), else 0.0 | 0  (predicate tapes only) |

### 3.3.1 Vector expressions are compile-time, not opcodes

`vec2`, `vec3`, vector `+` and `−`, scalar `*`, `dot`, `cross`, `norm`, and member access (`p.u`, `v0.v`, `e1.x`) have no opcodes. The expression compiler *scalarises* them: a `vec3` is three SSA registers, `dot(a,b)` expands to 3 MUL + 2 ADD, `cross(a,b)` to 6 MUL + 3 SUB, and `norm(a)` to `SQRT(dot(a,a))`. The tape stays purely scalar, so the dual-number rules above give exact derivatives for every vector expression with no extra cases.

Consequence: `norm(a)` has an undefined gradient at `a = 0` (the SQRT rule divides by zero) and raises `ERR_EXPR_NAN_INF` there. Constraints that may pass through zero length should be written in squared form, e.g. `dot(d,d) - L^2` instead of `norm(d) - L`.

### 3.3.2 Predicate tapes and evaluation context

A tape is compiled for one of three contexts, which fixes which variables `VAR` may bind and which opcodes are legal:

| Context | Used by | `VAR` binds | Extra opcodes |
| --- | --- | --- | --- |
| field | `<eq>`, `<ineq>`, `<field>`, `<def>` in `<implicit>` | `x, y, z` | — |
| residual | `<residual>`, `<assert>`, `<var>`/`<expr>` | declared unknowns and `<var>`s | — |
| predicate | `edge-predicate`, `face-predicate` | `x, y, z, nx, ny, nz, tx, ty, tz, k_min, k_max, k_gauss, k_mean, area, length` | `LT, GT, AND, OR, ABS, FROM_ID` |

Comparison and logic opcodes return 1.0 or 0.0 and have derivative 0. Operator precedence, high to low: unary `-`, `^`, `* /`, `+ -`, `< >`, `and`, `or`. `PROBE` is legal in every context. Using a predicate-only opcode or variable (`FROM_ID`, `nx`, `area`, …) in a field or residual tape is rejected at compile time with `ERR_EXPR_CONTEXT`. `ABS` is legal everywhere but is C⁰; field equations should use `abs_smooth`.

### 3.4 R-functions for boolean operations

Standard `min(f₁,f₂)` and `max(f₁,f₂)` for boolean union and intersection create C⁰ creases along the medial axis `f₁ = f₂`. These discontinuous gradients degrade dual contouring vertex placement and Newton-Raphson convergence.

CDML provides Rvachev R-function operators that maintain C¹ continuity everywhere except at exact boundary zeros:

- **`r_union(f₁, f₂)`** = `f₁ + f₂ − √(f₁² + f₂²)` — smooth union
- **`r_intersect(f₁, f₂)`** = `f₁ + f₂ + √(f₁² + f₂²)` — smooth intersection
- **`abs_smooth(u, ε)`** = `√(u² + ε²)` — C¹ absolute value

These are available as named functions in any `expr=` attribute and compile to opcodes 0x30, 0x31, and 0x25 respectively.

### 3.5 Variable declarations in `<defs>`

```xml
<defs>
  <!-- Scalar variable with optional bounds and unit -->
  <var id="R"  value="25.0" unit="mm" min="5.0" max="100.0"/>
  <var id="t"  value="4.0"  unit="mm"/>
  <var id="H"  value="40.0" unit="mm"/>

  <!-- Derived expression — compiled to SSA tape at load time -->
  <expr id="r"         expr="R - t"/>
  <expr id="bore_area" expr="PI * r^2"/>

  <!-- Design assertion — must hold after every parameter update -->
  <assert id="wall_check"
    expr="R - r - 2.0"
    error="bore too large for wall thickness"/>

  <!-- Named material -->
  <material id="steel">
    <prop name="E"   value="210e3" unit="MPa"/>
    <prop name="nu"  value="0.29"/>
    <prop name="rho" value="7.85e-3" unit="g/mm^3"/>
  </material>
</defs>
```

`<assert>` evaluates its `expr` after every parameter update. If the expression is negative the kernel emits `ERR_ASSERT_VIOLATED` with the assertion `id` and current variable values before any geometry is recomputed. This is the mechanism for encoding design intent as a constraint that participates in the solver loop rather than as a comment.

## 4. Equation Objects

There are exactly four geometric object types. All equation-defined geometry in CDML is one of these four; §4.5 defines how they become solids. No other shape tags exist.

| Element | DOF | Defined by | Example |
| --- | --- | --- | --- |
| `<point>` | 0 | n equations in n unknowns | intersection of three surfaces |
| `<curve>` | 1 | n−1 equations, or parametric r(t) | circle = cylinder ∩ plane |
| `<surface>` | 2 | 1 equation f(x,y,z)=0, or parametric r(u,v) | x²+y²−R²=0 |
| `<region>` | 3 | inequality f(x,y,z)≤0, or conjunction thereof | interior of a solid |

### 4.1 Surface

A surface is a 2-manifold defined by one scalar equation `f(x,y,z) = 0`.

```xml
<!-- A plane: z = 0 -->
<surface id="s_base">
  <eq>z</eq>
</surface>

<!-- Top plane at height H -->
<surface id="s_top">
  <eq>z - ref(H)</eq>
</surface>

<!-- Outer cylindrical wall: x²+y² - R² = 0 -->
<surface id="s_outer">
  <eq>x^2 + y^2 - ref(R)^2</eq>
</surface>

<!-- Inner bore -->
<surface id="s_inner">
  <eq>x^2 + y^2 - ref(r)^2</eq>
</surface>

<!-- Fillet canal surface: (√(x²+y²) - R)² + z² - r_f² = 0 -->
<surface id="s_fillet">
  <eq>(sqrt(x^2 + y^2) - ref(R))^2 + z^2 - ref(fillet_r)^2</eq>
</surface>

<!-- Gyroid TPMS: written as its equation, no template tag -->
<surface id="s_gyroid">
  <eq>
    sin(x * 2*PI / ref(period)) * cos(y * 2*PI / ref(period)) +
    sin(y * 2*PI / ref(period)) * cos(z * 2*PI / ref(period)) +
    sin(z * 2*PI / ref(period)) * cos(x * 2*PI / ref(period)) - ref(iso)
  </eq>
</surface>

<!-- Parametric surface: r(u,v) form when implicit is inconvenient -->
<surface id="s_nurbs" param-u="u" param-v="v"
         u-domain="0 1" v-domain="0 1">
  <x>...</x>
  <y>...</y>
  <z>...</z>
</surface>
```

The `<eq>` content is an expression string compiled to SSA bytecode. The surface is the zero-level set of this expression. The kernel evaluates both the primal `f(x,y,z)` and the gradient `∇f` via dual numbers — the gradient defines the outward normal everywhere on the surface without a separate declaration.

### 4.2 Curve

A curve is a 1-manifold. It can be defined implicitly as the intersection of two surfaces (two equations, one free DOF remaining) or parametrically as `r(t)`.

```xml
<!-- Implicit: circle at z=0, radius R — intersection of cylinder and base plane -->
<curve id="c_base_circle">
  <eq>x^2 + y^2 - ref(R)^2</eq>
  <eq>z</eq>
</curve>

<!-- Bore edge at top -->
<curve id="c_bore_top">
  <eq>x^2 + y^2 - ref(r)^2</eq>
  <eq>z - ref(H)</eq>
</curve>

<!-- Parametric: helix — implicit form would require two transcendental equations -->
<curve id="c_helix" param="t"
       domain-expr="0  ref(turns) * 2 * PI">
  <x>ref(R) * cos(t)</x>
  <y>ref(R) * sin(t)</y>
  <z>ref(pitch) * t / (2 * PI)</z>
</curve>

<!-- Parametric: involute of a circle (gear tooth profile) -->
<curve id="c_involute" param="t" domain="0 1.2">
  <x>ref(Rb) * (cos(t) + t * sin(t))</x>
  <y>ref(Rb) * (sin(t) - t * cos(t))</y>
  <z>0</z>
</curve>
```

For implicit curves, the kernel solves the two-equation system via Newton-Raphson with dual-number Jacobian. For parametric curves, evaluation is direct substitution.

### 4.3 Point

A point is a fully determined system — enough equations to reduce DOF to zero. The kernel solves via Newton-Raphson; `<hint>` seeds the solver when multiple solutions exist.

```xml
<!-- Origin: three equations, unique solution -->
<point id="p_origin">
  <eq>x</eq>
  <eq>y</eq>
  <eq>z</eq>
</point>

<!-- Point on the outer circle at angle 0 -->
<point id="p_corner">
  <eq>x^2 + y^2 - ref(R)^2</eq>
  <eq>z</eq>
  <eq>y</eq>   <!-- selects the positive-x solution -->
  <hint>ref(R) 0 0</hint>
</point>
```

`<hint>` is a numerical seed. It does not constrain the solution — it guides convergence. The solver verifies residuals to within `linear_tol` regardless of hint quality.

### 4.4 Region

A region is a closed subset of ℝ³ defined by one or more inequalities. `<ineq>f</ineq>` means `f ≥ 0`. The region is the conjunction (`<and>`) or disjunction (`<or>`) of active inequalities.

```xml
<!-- Cylindrical shell between inner and outer walls, bounded top and bottom -->
<region id="reg_shell">
  <and>
    <ineq>ref(R)^2 - x^2 - y^2</ineq>     <!-- x²+y² ≤ R² (inside outer) -->
    <ineq>x^2 + y^2 - ref(r)^2</ineq>     <!-- x²+y² ≥ r² (outside inner) -->
    <ineq>z</ineq>                          <!-- z ≥ 0 -->
    <ineq>ref(H) - z</ineq>               <!-- z ≤ H -->
  </and>
</region>

<!-- A half-space: everything below z = H/2 -->
<region id="reg_lower_half">
  <ineq>ref(H)/2 - z</ineq>
</region>
```

A `<region>` is consumed by `<brep region="…"/>` and `<implicit region="…">` as defined in §4.5. In `<csg>` it enters as an operand through one of those two wrappers.

### 4.5 How equation objects become solids

A `<region>` is the only §4 object that forms a solid. Solids consume it through a `region=` attribute on `<implicit>` or `<brep>`. Surfaces enter solids through region inequalities. Points and curves are reference geometry (see end of section).

**Surface inside a region.** `<ineq surface="s_outer" sense="-"/>` reads the equation `f` of surface `s_outer` and means `−f ≥ 0` (`sense="-"`, the side where `f ≤ 0`) or `f ≥ 0` (`sense="+"`). It is shorthand for re-typing the equation. An `<ineq>` may carry an `id`; that id is the `branch_hash` source for the face it generates (§10.1), so `from_id('i_outer')` selects that face.

**Implicit solid from a region.** `<implicit id="f" region="reg">` replaces the `<field>` element: an `<implicit>` has exactly one of `region=` or `<field>`. `<domain>` is still required, since a half-space region is unbounded. The field is built mechanically. Each `<ineq>` `fᵢ ≥ 0` becomes `Fᵢ = −fᵢ` (field convention: inside is `F ≤ 0`). `<and>` folds its children left to right with `r_intersect`, `<or>` with `r_union`, and nested groups are folded first. R-functions preserve the exact zero set, so the boundary is the region boundary.

**B-Rep solid from a region.** `<brep id="b" region="reg"/>` requires a pure conjunction (`<and>`, nested `<and>` allowed). Each `<ineq>` surface `fᵢ = 0` becomes the analytic surface of the face(s) lying where every other `<ineq>` holds; edges are the surface-surface intersections (§9.3). The kernel then checks Euler-Poincaré (§1.3). An unbounded region or one with empty interior is rejected with `ERR_REGION_UNBOUNDED`. A region containing `<or>` cannot be a B-Rep directly. Use `<implicit region=...>` or combine two regions in `<csg>`.

```xml
<region id="reg_ring">
  <and>
    <ineq id="i_outer" surface="s_outer" sense="-"/>  <!-- x²+y² ≤ R² -->
    <ineq id="i_inner" surface="s_inner" sense="+"/>  <!-- x²+y² ≥ r² -->
    <ineq id="i_bot">z</ineq>
    <ineq id="i_top">ref(H) - z</ineq>
  </and>
</region>

<!-- exact analytic solid: 4 faces, 4 edges (2 circles top, 2 bottom) -->
<brep id="solid_ring" region="reg_ring"/>

<!-- same region as a field, for lattices and field-driven booleans -->
<implicit id="field_ring" region="reg_ring">
  <domain xmin="-30" xmax="30" ymin="-30" ymax="30" zmin="0" zmax="40"/>
</implicit>
```

**Points and curves.** `<point>` and `<curve>` are reference geometry: they are solved and addressable by `id`, but no solid operation consumes them in v1.0. Natural consumers for a later revision are a curve as a sweep trajectory or wire source, and a point as a probe site.

## 5. Workplane (Chart2D)

A `<chart>` is a constrained coordinate frame — an isometric embedding `Φ: ℝ² → ℝ³` defined by `Φ(u,v) = p₀ + u·e₁ + v·e₂`. It is not a primitive plane; it is a constraint system whose solution is a plane.

Sketch geometry is authored in the (u,v) coordinate space of a chart. The chart resolves its own constraint system before any attached sketch is evaluated.

```xml
<!-- XY plane at z=0 — three constraints fully determine the frame -->
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

<!-- Tilted workplane: origin at z=20, 45° between e2 and Z -->
<chart id="chart_inlet">
  <vars>
    <vec3 id="p0" x="0.0" y="0.0" z="20.0" fixed="false"/>
    <vec3 id="e1" x="1.0" y="0.0" z="0.0"  fixed="false"/>
    <vec3 id="e2" x="0.0" y="0.0" z="0.0"  fixed="false"/>
  </vars>
  <constraints>
    <residual expr="dot(e1, e1) - 1.0"/>
    <residual expr="dot(e2, e2) - 1.0"/>
    <residual expr="dot(e1, e2)"/>
    <residual expr="dot(p0 - vec3(0, 0, 20), vec3(0, 0, 1))"/>
    <residual expr="dot(cross(e1, e2), vec3(0, 1, 0)) - cos(PI / 4.0)"/>
  </constraints>
</chart>
```

### 5.1 Chart constraint rules

A well-formed chart satisfies exactly three independent residuals for `(e1, e2)` — unit length, mutual orthogonality, and one orientation constraint. Under-constrained charts (`DOF > 0`) are permitted when the sketch attached to them provides the remaining constraints implicitly (e.g. a sketch that pins both `e2` direction and `p0` location). Over-constrained charts that are consistent (`OVER` state) are accepted with a warning; conflicting charts (`CONFLICTING` state) are rejected with `ERR_SKETCH_CONFLICT`.

### 5.2 Chart-to-world mapping

For any point `(u,v)` in sketch space, the world coordinates are:

```
P_world = p0 + u·e1 + v·e2
```

The kernel substitutes this mapping into all sketch curve equations before solving. Sketch constraints are written in `(u,v)` space; the chart resolves them into `(x,y,z)` space transparently.

## 6. Sketch System

A `<sketch>` groups free parameters — `<scalar>`, `<point2d>`, `<point3d>` — with curve definitions and algebraic residuals. It is authored in `(u,v)` space on a parent chart and produces wires (closed 1-manifolds) as output for B-Rep operations.

```xml
<sketch id="sk_flange" chart="chart_xy" max-iter="100">

  <!-- Free parameters: four corners of a square profile -->
  <vars>
    <point2d id="v0" u="-45.0" v="-45.0"/>
    <point2d id="v1" u=" 45.0" v="-45.0"/>
    <point2d id="v2" u=" 45.0" v=" 45.0"/>
    <point2d id="v3" u="-45.0" v=" 45.0"/>
  </vars>

  <!-- Outer wire: four degree-1 NURBS segments (lines) -->
  <wire id="wire_outer" closed="true" role="outer">
    <curve id="seg_bot" degree="1"
           ctrl="v0 v1" weights="1.0 1.0" knots="0 0 1 1"/>
    <curve id="seg_rgt" degree="1"
           ctrl="v1 v2" weights="1.0 1.0" knots="0 0 1 1"/>
    <curve id="seg_top" degree="1"
           ctrl="v2 v3" weights="1.0 1.0" knots="0 0 1 1"/>
    <curve id="seg_lft" degree="1"
           ctrl="v3 v0" weights="1.0 1.0" knots="0 0 1 1"/>
  </wire>

  <!-- Bore hole: exact circle via parametric equation in (u,v) -->
  <wire id="wire_bore" closed="true" role="hole">
    <param-curve id="c_bore" param="t" domain="0 1"
      u-expr="ref(r) * cos(2 * PI * t)"
      v-expr="ref(r) * sin(2 * PI * t)"/>
  </wire>

  <!-- Constraints: centre at origin, symmetric, square, correct width -->
  <constraints>
    <residual id="cx" expr="v0.u + v1.u"/>       <!-- centred in u -->
    <residual id="cy" expr="v0.v + v3.v"/>       <!-- centred in v -->
    <residual id="sym" expr="v2.u + v3.u"/>      <!-- top symmetric -->
    <residual id="horiz0" expr="v1.v - v0.v"/>   <!-- bottom edge horizontal -->
    <residual id="horiz1" expr="v2.v - v3.v"/>   <!-- top edge horizontal -->
    <residual id="ortho" expr="dot(v1-v0, v2-v1)"/> <!-- right angle -->
    <residual id="width" expr="norm(v1 - v0) - ref(flange_w)"/>
    <residual id="height" expr="norm(v2 - v1) - ref(flange_w)"/>
  </constraints>

</sketch>
```

### 6.1 Curve representation

Every `<curve>` in a sketch is a rational B-spline of degree `p` over a non-decreasing knot vector:

```
C(t) = Σ Nᵢ,ₚ(t) · wᵢ · Pᵢ / Σ Nᵢ,ₚ(t) · wᵢ
```

where control point coordinates reference indices in the sketch parameter vector. Degree-1 with unit weights and open knot vectors `[0 0 1 1]` gives exact line segments. Degree-2 with weights `[1, 1/√2, 1]` and knots `[0 0 0 1 1 1]` gives an exact quarter-circle arc. These are not primitives — they are NURBS configurations.

`<param-curve>` is a parametric curve defined by `u-expr` and `v-expr` in parameter `t`. It compiles the same SSA bytecode path as all other expressions. It is not a separate type — it is a `<curve>` whose control equations happen to be explicit functions of a single parameter rather than a constraint system.

### 6.2 Solver and DOF classification

Given M residuals over N free parameters, the kernel assembles the exact Jacobian `J(q) ∈ ℝᴹˣᴺ` via dual numbers and performs Householder QR with column pivoting:

```
J·P = Q·[R₁₁  R₁₂]
          [0    0  ]
```

where `R₁₁ ∈ ℝʳˣʳ` has numerical rank `r` (diagonal entries `|Rᵢᵢ| > ε_rank = 1e-10`).

| State | Condition | Behaviour |
| --- | --- | --- |
| `SOLVED` | `‖R(q)‖∞ ≤ ε_lin` and `DOF = 0` | Fully determined. Proceeds. |
| `UNDER` | `‖R(q)‖∞ ≤ ε_lin` and `DOF > 0` | Minimum-norm solution from initial guess. Warning emitted. |
| `OVER` | `M > r`, residuals consistent | Dependent rows ignored. Warning emitted. |
| `CONFLICTING` | `‖R(q)‖∞ > ε_lin`, non-zero left-nullspace projection | Rejected. `ERR_SKETCH_CONFLICT` with conflicting residual IDs. |

A sketch with no `<vars>` and no `<constraints>` is valid: `N = 0`, `DOF = 0`, state `SOLVED`. This is the form for geometry given entirely by explicit parametric curves, such as a circle written as `r(t)`.

### 6.3 Wire validity

Before a wire is accepted as input to a B-Rep operation, the kernel verifies:

- **Closed:** start point of first curve equals end point of last curve to within `linear_tol`.
- **Non-self-intersecting:** no two non-adjacent curve segments share a point in their interiors.
- **Consistent orientation:** for an `outer` wire, the signed area in `(u,v)` is positive; for a `hole` wire, negative.

Violations emit `ERR_WIRE_OPEN_OR_SELF_INT` with the gap distance or intersection `(u,v)` coordinates.

**Profile validity.** When several wires are swept together (§7.1), exactly one has `role="outer"`, every `hole` wire lies strictly inside it, and hole wires are pairwise disjoint. Violations are rejected with `ERR_PROFILE_INVALID` naming the offending wire ids.

## 7. B-Rep Solids

A `<brep>` solid builds exact boundary topology in a half-edge structure. It consumes wires from sketches and produces a manifold solid with analytical surface descriptions attached to every face. The kernel computes face normals via dual numbers from the surface equations — no separate normal declarations.

### 7.1 Kinematic SE(3) sweep

A `<sweep>` extrudes a closed wire along a rigid-body trajectory `T(v) = (R(v), d(v)) ∈ SE(3)` for `v ∈ [0,1]`. Rotation is parameterised via the Lie algebra exponential map `R(v) = exp(θ(v)·[ω̂(v)]×)`. The swept surface at parameter `(u,v)` is:

```
S(u,v) = R(v)·C(u) + d(v)
```

The outward normal is computed analytically as `N(u,v) = ∂S/∂u × ∂S/∂v` via dual numbers.

```xml
<brep id="solid_flange">

  <!-- Pure linear extrusion: R(v)=I, d(v)=(0,0,H·v) -->
  <sweep id="sw_extrude" wire="wire_outer" cap-ends="true">
    <trajectory>
      <translate x="0" y="0" z-expr="ref(H) * v"/>
    </trajectory>
  </sweep>

  <!-- Helical sweep: rotation + translation coupled -->
  <sweep id="sw_helix" wire="wire_profile" cap-ends="false">
    <trajectory>
      <rotate  axis="0 0 1" angle-expr="ref(turns) * 2 * PI * v"/>
      <translate x="0" y="0" z-expr="ref(H) * v"/>
    </trajectory>
  </sweep>

  <!-- Differential rolling-ball fillet on vertical outer edges -->
  <!-- No edge named by id — selected by a geometric predicate -->
  <fillet id="fillet_corners"
    edge-predicate="abs(tz) > 0.999 and x^2 + y^2 > (ref(r) + ref(wall_margin))^2"
    radius-expr="ref(fillet_r)"/>

</brep>
```

**Sweep self-intersection check.** During sweep evaluation the kernel monitors `min_{u,v} ‖∂S/∂u × ∂S/∂v‖` using interval arithmetic. If the Jacobian determinant crosses zero, the sweep aborts with `ERR_SWEEP_SELF_INTERSECT` reporting the critical `(u*, v*)` coordinates.

**Profile selection.** A `<sweep>` takes exactly one of:

- `wire="w"` — a single wire (no holes).
- `wires="w_outer w_hole1 …"` — one wire with `role="outer"` plus any number with `role="hole"`.
- `sketch="sk"` — shorthand for every wire of the sketch.

Holes are swept together with the outer wire, so a hole wire produces its own lateral faces and a matching inner loop on each cap face (the `L` term in Euler-Poincaré). Faces generated by a wire carry that wire's curve ids in `branch_hash`, so `from_id('c_bore')` selects the bore faces. Profile validity rules are in §6.3.

```xml
<!-- Perforated flange: outer square and bore swept as one profile -->
<sweep id="sw_extrude" sketch="sk_flange" cap-ends="true">
  <trajectory>
    <translate x="0" y="0" z-expr="ref(flange_h) * v"/>
  </trajectory>
</sweep>
```

### 7.2 Tensor loft

A `<loft>` interpolates an ordered sequence of K ≥ 2 compatible wires across parameter `v ∈ [0,1]` with specified cross-boundary continuity.

```xml
<brep id="solid_nozzle">
  <loft id="loft_body" continuity="G1" cap-ends="true">
    <section v="0.0" wire="wire_inlet"/>
    <section v="0.5" wire="wire_mid"/>
    <section v="1.0" wire="wire_outlet"/>
  </loft>
</brep>
```

`continuity` values: `G0` (position only), `G1` (tangent continuous), `G2` (curvature continuous). The kernel fits a bivariate tensor-product NURBS surface to the sections satisfying the cross-boundary derivative conditions.

### 7.3 Envelope fillet

An `<fillet>` replaces sharp edges matching `edge-predicate` with a canal surface — a sphere of radius `r(s)` maintaining tangential contact with the two adjacent faces:

```
F(u₁,v₁,u₂,v₂,s) = ‖S₁(u₁,v₁) - S₂(u₂,v₂)‖² - (2r(s))² = 0
```

**Fillet radius collapse.** If `r · κ_edge(s) ≥ 1 - ε_lin` for any arc parameter `s`, the fillet would consume the adjacent face entirely. The kernel fails fast with `ERR_FILLET_RADIUS_COLLAPSE` and reports `r_max = 1/max_s(κ_edge(s)) - 1e-4 mm`.

## 8. Implicit Solids

An `<implicit>` solid defines a closed subset of ℝ³ via a compiled scalar field `F(x,y,z) ≤ 0` restricted to an axis-aligned `<domain>`. No mesh is stored — the field is the geometry.

```xml
<implicit id="solid_gyroid">

  <domain
    xmin="-45.0" xmax="45.0"
    ymin="-45.0" ymax="45.0"
    zmin="0.0"   zmax="16.0"
    octree-depth="6"
    qef-reg="1e-4"/>

  <!-- Local named expressions: scoped to this implicit block -->
  <def name="omega" expr="2 * PI / ref(period)"/>
  <def name="g"
    expr="sin(omega*x)*cos(omega*y) +
          sin(omega*y)*cos(omega*z) +
          sin(omega*z)*cos(omega*x)"/>
  <!-- Stress field read from simulation slot 0; default 40 MPa if unset -->
  <def name="stress" expr="field_scalar(0, x, y, z, 40.0)"/>
  <def name="t_wall" expr="0.9 + 0.01 * stress"/>

  <!-- The field equation: inside where this ≤ 0 -->
  <field expr="abs_smooth(g, 1e-4) - (0.5 * omega * t_wall)"/>

</implicit>
```

### 8.1 Field equation requirements

- `F(x,y,z)` must be continuous and piecewise differentiable on `<domain>`.
- `‖∇F(x)‖` must be bounded away from zero near the zero isosurface: `0 < c_min ≤ ‖∇F‖ ≤ c_max` for `|F(x)| < δ`. Fields with `‖∇F‖ < 1e-12` on the isosurface are rejected with `ERR_IMPLICIT_GRAD_ZERO`.
- If `F(x,y,z) > 0` everywhere in `<domain>`, the kernel emits `ERR_IMPLICIT_EMPTY_DOMAIN` with the minimum sampled value.
- `abs_smooth` and `r_union` / `r_intersect` are the preferred operations for composing field expressions because they preserve C¹ continuity and bounded gradients.

A field can also be derived from a §4 `<region>` instead of being written out: see `<implicit region="…">` in §4.5.

### 8.2 Local definitions

`<def name="..." expr="...">` is a scoped named expression inside an `<implicit>` block. It is not assignment — it is a named subexpression that the compiler inlines. The `name` attribute is syntactic sugar; the kernel substitutes it everywhere it appears in subsequent `expr=` strings within the same block. Definitions must form a DAG (no mutual recursion).

This is distinct from `<expr id="...">` in `<defs>`, which is document-scoped and available everywhere. Use `<def>` for intermediate expressions that are only meaningful in context of the field equation.

### 8.3 Tessellation via Dual Contouring

When an export target requests a mesh, the kernel subdivides `<domain>` into an adaptive octree using interval arithmetic (cells where `F_min > τ` and `F_max < -τ` are pruned), then places one dual vertex per active cell by minimising the Quadratic Error Function:

```
QEF(v) = Σₖ (nₖ · (v - pₖ))²
```

where `pₖ` are edge intersection points and `n̂ₖ = ∇F(pₖ) / ‖∇F(pₖ)‖` are exact dual-number normals. `qef-reg` is a regularisation term added to the QEF diagonal to stabilise near-flat regions.

### 8.4 Field sampling

`field_scalar(slot_id, x, y, z, default)` reads a scalar value from the simulation field buffer at slot `slot_id`. If the slot is unallocated, it returns `default` with zero gradient. If `(x,y,z)` lies outside the grid bounds, coordinates clamp to the boundary voxel (CLAMP\_TO\_EDGE) to preserve C⁰ continuity. This is how simulation-driven geometry adaptation works: a stress field computed by an FEA extension populates slot 0, and the field equation above thickens gyroid walls in high-stress regions.

## 9. CSG Bridge

A `<csg>` solid stores a lazy binary expression tree. Operands can be any combination of `<brep>`, `<implicit>`, or nested `<csg>` nodes. The tree is not evaluated until a downstream operation (tessellation, export, or fillet) requests a resolved solid.

```xml
<csg id="solid_assembly">

  <!-- Core mask: implicit field defining the infill zone -->
  <implicit id="solid_mask">
    <domain xmin="-45" xmax="45" ymin="-45" ymax="45" zmin="0" zmax="16"/>
    <def name="r"   expr="sqrt(x^2 + y^2)"/>
    <def name="d_box"
      expr="r_intersect(
              abs_smooth(x, 1e-3) - (ref(flange_w)*0.5 - ref(wall_margin)),
              abs_smooth(y, 1e-3) - (ref(flange_w)*0.5 - ref(wall_margin)))"/>
    <def name="d_z"
      expr="abs_smooth(z - ref(H)*0.5, 1e-3) - (ref(H)*0.5 - ref(wall_margin))"/>
    <def name="d_in" expr="(ref(r) + ref(wall_margin)) - r"/>
    <field expr="r_intersect(r_intersect(d_box, d_z), d_in)"/>
  </implicit>

  <!-- Boolean tree -->
  <boolean id="lattice_core" op="intersect"
    left="solid_mask" right="solid_gyroid"/>

  <boolean id="hollow_shell" op="subtract"
    left="solid_flange" right="solid_mask"/>

  <boolean id="final" op="union"
    left="hollow_shell" right="lattice_core"
    preserve-brep-tags="true"
    collar-tol="1e-6"/>

</csg>
```

### 9.1 Resolution strategy by operand types

| Left | Right | Resolution |
| --- | --- | --- |
| `<brep>` + `<brep>` | exact SSI marching along `S₁−S₂=0`, result promoted to `<brep>`. Downstream fillets and STEP export remain exact. |  |
| `<brep>` + `<implicit>` | B-Rep faces triangulated with exact normals and persistent `TopoId` tags; implicit region contoured via QEF Dual Contouring; stitched along shared boundary. |  |
| `<implicit>` + `<implicit>` | Both fields composed via R-functions: union = `r_union(F₁,F₂)`, subtract = `r_intersect(F₁,−F₂)`, intersect = `r_intersect(F₁,F₂)`. Single composed field passed to Dual Contouring. |  |
| Any + `<csg>` | Recursively resolve children first, then apply parent operation. |  |

### 9.2 Boolean operations

The three operations and their field arithmetic equivalents:

| `op=` | Set operation | Field form (implicit) | Exact B-Rep form |
| --- | --- | --- | --- |
| `"union"` | A ∪ B | `r_union(F_A, F_B)` | SSI + merge boundary loops |
| `"subtract"` | A \\ B | `r_intersect(F_A, −F_B)` | SSI + invert B face orientation |
| `"intersect"` | A ∩ B | `r_intersect(F_A, F_B)` | SSI + keep interior loops only |

### 9.3 Grazing surface-surface intersection

When two B-Rep surfaces intersect along a curve where `‖n̂₁ × n̂₂‖ < ε_ang`, the standard 4×4 marching Jacobian becomes singular. The kernel switches to second-order Dupin indicatrix analysis using the relative normal curvature tensor `II₁ − II₂`. If surfaces coincide over a 2D patch (`|S₁ − S₂| ≤ ε_lin` across the face domain), the boolean classifier merges coplanar faces and unifies their boundary half-edges. Failure emits `ERR_SSI_CONVERGENCE`.

### 9.4 Hybrid B-Rep/implicit boundary collar

When an implicit isosurface lies within `ε_lin` of a preserved B-Rep face, zero-thickness sliver triangles form. `preserve-brep-tags="true"` enforces a signed collar offset `±δ_collar` (`δ_collar = collar-tol`, default `10·ε_lin`) on implicit field evaluation along the B-Rep interface. All Dual Contouring vertices snap onto the exact B-Rep trim curves rather than floating near them.

## 10. Topological Naming

Every topological sub-shape (vertex, edge, wire, face, shell, solid) carries a deterministic 192-bit `TopoId` (three 64-bit words). This is distinct from the XML `id` attribute. XML `id` identifies a document element; `TopoId` identifies a geometric sub-shape within the evaluated solid. `TopoId` is stable across upstream parameter recomputation as long as the topology does not change.

### 10.1 Structure and hashing

| Word | Bits | Field | Description |
| --- | --- | --- | --- |
| 0 | 0–63 | `feature_hash` | `H64` of the fully qualified `id` of the originating element |
| 1 | 0–63 | `branch_hash` | `H64` of the generating curve, wire, or trajectory id (a synthetic id if it has none) |
| 2 | 0–3 | `subshape_type` | 1=Vertex, 2=Edge, 3=Wire, 4=Face, 5=Shell, 6=Solid |
| 2 | 4–11 | `topo_flags` | Bitflags: Preserve, Boundary, Analytic, ImplicitInterface |
| 2 | 12–43 | `split_generation` | Monotonic counter incremented on boolean or fillet splits |
| 2 | 44–63 | reserved | Must be zero |

`TopoId` values are never written in CDML source documents. They are emitted by the kernel in diagnostic payloads and tessellation outputs, and read by simulation extensions from the tessellation buffer.

### 10.1.1 Hash function and collision detection

**Hash.** `H64(s)` is the first 8 bytes, read as a big-endian unsigned integer, of the SHA-256 digest of the UTF-8 encoding of `s`. `s` is the fully qualified id, meaning the `id` attribute after import prefixing (§2a), so an imported `bolt_d` hashes as `fs.bolt_d`. Both hash fields use the same function. `from_id(x)` therefore compiles to two integer comparisons: `feature_hash == H64(x)` or `branch_hash == H64(x)`.

**Why 64 bits per field.** `TopoId` must stay unique, and `from_id` unambiguous, across every id in the document, imports included. By the birthday bound the chance that any two of `n` ids share a hash is about `n² / 2⁶⁵`. That is roughly 3·10⁻⁸ for a million ids. A 20-bit hash reaches a 50% chance of collision at about 1,200 ids, which is why the earlier layout was unsafe for real assemblies.

**Collision rule (normative).** After imports are merged, the parser computes `H64` over every `id` in the document, including synthetic ids. If two distinct ids share a value, the document is rejected with `ERR_ID_HASH_COLLISION` naming both ids, and the author renames one. A kernel must not silently salt or rehash, because a salt would make `TopoId`s depend on document order and break persistence. The check uses id strings only, so every conforming implementation gives the same verdict, and a document that passes cannot produce a false `from_id` match from hash coincidence.

**Synthetic ids.** A generator with no XML `id` of its own, such as an `<ineq>` without one, uses `<parent_id>#<n>`, where `n` is its 0-based position among its siblings. Reordering siblings changes these ids, so give an `id` to anything whose name must survive edits.

**Counter overflow.** An operation that would push `split_generation` past 2³² − 1 is rejected with `ERR_TOPOID_OVERFLOW`.

**Ordering and storage.** `TopoId`s order lexicographically by (word 0, word 1, word 2). This document fixes only the three-word structure. The in-memory layout of the tessellation output is defined by the Kernel Reference, and nothing in a CDML document depends on it.

### 10.2 Differential predicates

Face and edge selection in `<fillet>`, `<probe>`, and extension configuration is done by predicate expressions, not by raw `TopoId` values or array indices. The predicate compiler binds the following intrinsic variables for each candidate sub-shape:

| Variable | Type | Definition |
| --- | --- | --- |
| `x, y, z` | scalar | Centroid of the face or edge in world mm |
| `nx, ny, nz` | scalar | Outward unit normal at face centroid |
| `tx, ty, tz` | scalar | Unit tangent at edge midpoint |
| `k_min, k_max` | scalar | Principal curvatures κ₁, κ₂ |
| `k_gauss` | scalar | Gaussian curvature κ₁·κ₂ |
| `k_mean` | scalar | Mean curvature (κ₁+κ₂)/2 |
| `area` | scalar | Face area in mm² |
| `length` | scalar | Edge arc length in mm |
| `from_id("xml_id")` | scalar | 1.0 if the sub-shape's feature\_hash or branch\_hash equals H64 of the named id (§10.1.1) |

Examples:

```xml
<!-- All vertical edges on the outer wall -->
edge-predicate="abs(tz) > 0.999 and x^2 + y^2 > ref(r)^2"

<!-- All cylindrical faces (zero Gaussian curvature, nonzero mean) -->
face-predicate="abs(k_gauss) < 1e-9 and abs(k_mean) > 1e-6"

<!-- Base face: flat and at z ≈ 0 -->
face-predicate="abs(nz + 1.0) < 1e-6 and abs(z) < 1e-4"

<!-- Faces originating from the bore curve -->
face-predicate="from_id('c_bore')"
```

Predicates are evaluated via the same SSA bytecode engine as all other expressions. They receive exact curvature values computed from the analytical surface equations via dual numbers — not approximated from the tessellation mesh.

### 10.3 Non-manifold rejection

After every B-Rep operation, the kernel counts incident shells per vertex and incident faces per directed half-edge. If any edge has more than 2 incident faces, or an odd number, the operation is rejected with `ERR_NON_MANIFOLD_EDGE` and the handle is not committed. The Euler-Poincaré equation is checked as a necessary (not sufficient) condition after this.

## 11. Composition and Assembly

Multiple solids of any representation tier are combined into a final result via `<compose>`. This is the top-level assembly element inside `<body>`. It is not a CSG operation — it assigns semantic roles to already-evaluated solids and declares how they relate spatially.

```xml
<body>

  <compose id="housing_final">

    <!-- Outer shell: exact B-Rep, preserved for STEP export -->
    <layer ref="solid_flange" role="shell"/>

    <!-- Interior void -->
    <layer ref="solid_bore"   role="void"/>

    <!-- Gyroid infill clipped inside shell, outside void -->
    <layer ref="solid_gyroid" role="fill"
           inside="solid_flange"
           outside="solid_bore"/>

  </compose>

</body>
```

### 11.1 Layer roles

| `role=` | Meaning |
| --- | --- |
| `"shell"` | The bounding solid. Defines the exterior envelope. |
| `"void"` | A region removed from the shell. Applied as subtract. |
| `"fill"` | A solid inserted into the interior. Clipped by `inside` and `outside`. |
| `"feature"` | A local modification (thread, boss, rib) added to the shell. |

### 11.2 Transform

Any layer or solid can carry a `<transform>` that composes into the solid's equation via `f(M⁻¹·x) = 0`. The transform modifies the equation directly — no mesh involved.

```xml
<!-- Four bolt holes at 90° intervals -->
<csg id="bolt_holes">
  <boolean op="union">
    <brep ref="solid_bolt_hole" id="bh_0"/>
    <brep ref="solid_bolt_hole" id="bh_1">
      <transform><rotate axis="0 0 1" angle="PI/2"/></transform>
    </brep>
    <brep ref="solid_bolt_hole" id="bh_2">
      <transform><rotate axis="0 0 1" angle="PI"/></transform>
    </brep>
    <brep ref="solid_bolt_hole" id="bh_3">
      <transform><rotate axis="0 0 1" angle="3*PI/2"/></transform>
    </brep>
  </boolean>
</csg>
```

All angle attributes follow the numeric attribute contract — literals, `ref=`, or `expr=` are equivalent.

### 11.3 Repeat (pattern macro)

Repeated features are expressed as transforms in a loop. `<repeat>` is syntactic sugar that expands to `<boolean op="union">` over transformed copies at evaluation time. No new schema concept is introduced.

```xml
<!-- Six bolt holes equally spaced on a PCD -->
<repeat id="bolt_pattern" count="6" ref="solid_bolt_hole">
  <transform>
    <rotate axis="0 0 1" angle-expr="2 * PI * i / 6"/>
    <translate x-expr="ref(bolt_pcd) * cos(2*PI*i/6)"
               y-expr="ref(bolt_pcd) * sin(2*PI*i/6)"
               z="0"/>
  </transform>
</repeat>
```

`i` is the loop index variable, available only inside `<repeat>` transform expressions. The expansion is a `<boolean op="union">` tree over `count` copies evaluated at load time.

## 12. Field Slots and Probes

The `<simulation>` section is removed. Its concepts split cleanly into two things that already belong in the format:

- **`<field-slot>`** in `<defs>` — declares a named scalar grid readable via `field_scalar()` in any field equation.
- **`<probe>`** in `<body>` — queries a geometric or field quantity from a solid and binds the result to a name usable in any downstream `expr=`.

Extension-specific boundary conditions (`dirichlet-bc`, `neumann-bc`) are not geometry. They belong in the extension's own configuration, not in CDML.

### 12.1 Field slots in `<defs>`

```xml
<defs>
  <!-- Slot 0: Von Mises stress, 64×64×24 voxels.
       Written by an FEA extension. Default 40.0 MPa until populated. -->
  <field-slot id="stress_field" slot="0"
              semantic="stress"
              grid-x="64" grid-y="64" grid-z="24"
              default="40.0"/>

  <!-- Slot 1: temperature from a thermal solver -->
  <field-slot id="temp_field" slot="1"
              semantic="temperature"
              grid-x="32" grid-y="32" grid-z="16"
              default="20.0"/>
</defs>
```

| Attribute | Meaning |
| --- | --- |
| `slot` | Integer index used in `field_scalar(slot, x, y, z, default)` |
| `semantic` | Human-readable label: `"stress"`, `"temperature"`, `"density"` |
| `grid-x/y/z` | Voxel resolution |
| `default` | Fallback value when unallocated or out-of-bounds |

Field slots can be imported:

```xml
<import src="lib/fea_fields.cdml" select="stress_field"/>
```

### 12.2 Probes

A `<probe>` is a named query that extracts a scalar quantity from a solid — at a point, or aggregated over faces or edges matching a predicate — and binds it to a name usable via `probe("id")` in any `expr=` attribute declared after the probe.

```xml
<!-- Point probe: field value at a specific world location -->
<probe id="stress_at_bore_top"
       type="point"
       target="solid_final"
       x="0" y-ref="bore_r" z-ref="flange_h"
       quantity="field_scalar(0, x, y, z, 40.0)"/>

<!-- Face probe: mean field value over faces matching a predicate -->
<probe id="mean_bore_stress"
       type="face-mean"
       target="solid_flange"
       face-predicate="from_id('c_bore') and abs(k_gauss) < 1e-9"
       quantity="field_scalar(0, x, y, z, 40.0)"/>

<!-- Face probe: peak value over fillet faces -->
<probe id="max_fillet_stress"
       type="face-max"
       target="solid_final"
       face-predicate="abs(k_gauss) > 1e-6"
       quantity="field_scalar(0, x, y, z, 40.0)"/>

<!-- Geometric probe: total bore face area -->
<probe id="bore_face_area"
       type="face-sum"
       target="solid_final"
       face-predicate="from_id('c_bore')"
       quantity="area"/>

<!-- Volume probe: total enclosed volume -->
<probe id="housing_volume"
       type="volume"
       target="solid_final"/>
```

### 12.3 Probe types

| `type=` | Input | `quantity=` evaluates | Result |
| --- | --- | --- | --- |
| `"point"` | `x=`, `y=`, `z=` world coords | any `expr` in `(x,y,z)` | single scalar |
| `"face-mean"` | `face-predicate=` | face intrinsic or `field_scalar()` | mean over matching faces |
| `"face-max"` | `face-predicate=` | face intrinsic or `field_scalar()` | maximum over matching faces |
| `"face-sum"` | `face-predicate=` | `area`, `length`, or scalar field | sum over matching faces |
| `"edge-mean"` | `edge-predicate=` | edge intrinsic | mean over matching edges |
| `"volume"` | `target=` solid | — | enclosed volume in mm³ |

All `quantity=` expressions use the same SSA bytecode engine and predicate vocabulary as §10.2. `x, y, z` in a `"point"` probe bind to the coordinates given by the probe's own `x=`, `y=`, `z=` attributes.

### 12.4 Using probe results

`probe("id")` reads the named probe's result in any `expr=` attribute that appears after the probe declaration.

```xml
<!-- Assert peak stress never exceeds yield margin -->
<assert id="stress_limit"
  expr="200.0 - probe('max_fillet_stress')"
  error="fillet stress exceeds 200 MPa"/>

<!-- Adapt gyroid wall to mean bore stress rather than raw field sample -->
<implicit id="solid_gyroid_adaptive">
  <domain xmin="-45" xmax="45" ymin="-45" ymax="45" zmin="0" zmax="16"/>
  <def name="omega" expr="2 * PI / ref(period)"/>
  <def name="g"
    expr="sin(omega*x)*cos(omega*y) +
          sin(omega*y)*cos(omega*z) +
          sin(omega*z)*cos(omega*x)"/>
  <def name="t_wall" expr="0.9 + 0.005 * probe('mean_bore_stress')"/>
  <field expr="abs_smooth(g, 1e-4) - (0.5 * omega * t_wall)"/>
</implicit>
```

Probes are evaluated lazily: the result is computed the first time it is referenced. If the target solid is not yet tessellated, the kernel tessellates it at document default tolerance first.

### 12.5 Pre- and post-extension probes

- **Pre-extension:** geometric intrinsics (`area`, `k_gauss`, `length`, etc.) are available immediately from exact analytical geometry, with no field slot required.
- **Post-extension:** `field_scalar()` quantities return `default` until the extension populates the slot, then return the real field value on the next probe evaluation.

This is the complete replacement for `<dirichlet-bc>` and `<neumann-bc>`. An FEA extension reads face predicates from its own configuration (expressed in the same predicate vocabulary) and queries probe results. The CDML file declares *what to measure*; the extension decides *what to do with it*.

### 12.6 Dependency rules

A probe adds two kinds of edges to the document DAG (§2): probe → its `target` solid (that solid must be evaluated and tessellated first), and every element whose `expr=` calls `probe('id')` → that probe. The normal cycle check applies. A probe must not be read, directly or through a chain, by any element its `target` depends on. A violation is rejected at parse time with `ERR_DAG_CYCLE` naming the chain, e.g. `solid_gyroid → probe:mean_bore_stress → solid_final → solid_gyroid`.

`field_scalar()` is **not** an edge. A field slot is external state written by an extension between evaluation passes (§12.1), so reading it creates no dependency on whatever wrote it. This is what makes the stress-adaptive loop legal. The gyroid reads `probe('mean_bore_stress')`; the probe samples the slot on the bore faces of `solid_flange`; the extension writes the slot after the previous pass's tessellation. The feedback loop runs across passes, not inside the DAG, and so needs no special "previous pass" flag. Every slot read already returns the last written value, or `default` before the first write.

Practical rule: point a probe at the smallest upstream solid that contains the faces it needs. The field lives in world space, so the value sampled at a face is the same whether `target` is `solid_flange` or the final assembly, provided downstream booleans leave those faces unchanged. Targeting the final assembly from something the assembly contains is a cycle.

Declaration order: a probe must be declared before the first element that reads it (§12.4).

## 13. Error Codes and Degeneracy Protocols

Every kernel function returns a 32-bit `cdml_status_t`. On failure the kernel writes a structured diagnostic record to a scratch buffer. The payload is machine-readable so a host or autonomous agent can self-correct without guessing.

### 13.1 Error code table

| Code | Name | Subsystem | Trigger |
| --- | --- | --- | --- |
| 0x0000 | `CDML_OK` | Global | Success |
| 0x0101 | `ERR_XML_SYNTAX` | Parser | Malformed XML |
| 0x0102 | `ERR_SCHEMA_VERSION` | Parser | `version` mismatch |
| 0x0103 | `ERR_DAG_CYCLE` | Parser | Circular dependency in `<defs>` or `<csg>` |
| 0x0104 | `ERR_UNDEFINED_REF` | Parser | `ref=` or `from_id()` targets unknown `id` |
| 0x0201 | `ERR_EXPR_DIV_ZERO` | Autodiff | Division by zero or `log(x≤0)` |
| 0x0202 | `ERR_EXPR_NAN_INF` | Autodiff | Evaluation produced NaN or Inf |
| 0x0203 | `ERR_ASSERT_VIOLATED` | Autodiff | `<assert>` expression negative after parameter update |
| 0x0301 | `ERR_SKETCH_CONFLICT` | Solver | Over-constrained inconsistent residuals |
| 0x0302 | `ERR_SKETCH_DIVERGED` | Solver | Newton-Raphson exceeded `max-iter` |
| 0x0303 | `ERR_WIRE_OPEN_OR_SELF_INT` | Sketch | Wire not closed or self-intersects |
| 0x0401 | `ERR_SWEEP_SELF_INTERSECT` | B-Rep | Swept surface normal collapses to zero |
| 0x0402 | `ERR_FILLET_RADIUS_COLLAPSE` | B-Rep | Fillet radius exceeds local edge curvature |
| 0x0403 | `ERR_SSI_CONVERGENCE` | B-Rep | Surface-surface intersection marching failed |
| 0x0404 | `ERR_EULER_POINCARE` | Topology | `V−E+F−(L−F)−2(S−G) ≠ 0` |
| 0x0405 | `ERR_NON_MANIFOLD_EDGE` | Topology | Edge shared by ≠ 2 half-edges |
| 0x0501 | `ERR_IMPLICIT_EMPTY_DOMAIN` | Implicit | `F > 0` everywhere in `<domain>` |
| 0x0502 | `ERR_IMPLICIT_GRAD_ZERO` | Implicit | `‖∇F‖ < 1e-12` on zero isosurface |

Nine additional error codes are added to the table in §13.1 for imports and probes:

| Code | Name | Subsystem | Trigger |
| --- | --- | --- | --- |
| 0x0105 | `ERR_IMPORT_CONFLICT` | Parser | Imported `id` collides with local or prior-import `id` |
| 0x0106 | `ERR_IMPORT_NOT_FOUND` | Parser | `src=` path does not resolve to a readable CDML file |
| 0x0503 | `ERR_PROBE_INVALID_TARGET` | Probe | `target=` solid does not exist or has not been evaluated |
| 0x0504 | `ERR_PROBE_NO_MATCH` | Probe | `face-predicate=` or `edge-predicate=` matched zero sub-shapes |
| 0x0204 | ERR\_EXPR\_CONTEXT | Autodiff | Predicate-only opcode or variable used in a field or residual tape (§3.3.2) |
| 0x0304 | ERR\_PROFILE\_INVALID | Sketch | Multi-wire profile without exactly one outer wire, or a hole outside the outer wire or overlapping another hole |
| 0x0406 | ERR\_REGION\_UNBOUNDED | B-Rep | \<brep region=…> region is unbounded, has empty interior, or contains \`\<or>\` |
| 0x0107 | ERR\_ID\_HASH\_COLLISION | Parser | Two distinct ids, synthetic ids included, share an H64 value (§10.1.1) |
| 0x0407 | ERR\_TOPOID\_OVERFLOW | Topology | split\_generation would exceed 2^32 − 1 |

Every error diagnostic includes the triggering element `id`, the offending parameter values, and where applicable exact `TopoId` references — so the diagnostic can be parsed and acted on programmatically.

### 13.2 Degeneracy resolution protocols

**Case 1 — Sketch bifurcation.** A distance constraint `‖p₁−p₀‖²−d²=0` has two mirror-symmetric roots. Resolution: use signed oriented-area residuals `det([p₁−p₀, p₂−p₀]) > 0` and homotopy continuation, subdividing `Δq` into sub-steps when `‖Δq‖∞` exceeds 25% of the sketch bounding box.

**Case 2 — Grazing surface-surface intersection.** When `‖n̂₁ × n̂₂‖ < 1e-7`, the marching Jacobian is singular. Resolution: switch to Dupin indicatrix analysis via `II₁ − II₂`. If surfaces coincide over a 2D patch, merge coplanar faces and unify boundary half-edges.

**Case 3 — Sweep self-intersection.** Resolution: monitor `min_{u,v} ‖∂S/∂u × ∂S/∂v‖` via interval arithmetic during sweep. Abort with `ERR_SWEEP_SELF_INTERSECT` at the first zero crossing, reporting `(u*, v*)`.

**Case 4 — Fillet radius collapse.** Resolution: if `r · κ_edge(s) ≥ 1 − ε_lin`, fail fast with `ERR_FILLET_RADIUS_COLLAPSE` and report `r_max = (max_s κ_edge(s))⁻¹ − 1e-4 mm`.

**Case 5 — Hybrid coplanar grazing.** Resolution: enforce collar offset `±δ_collar = 10·ε_lin` on implicit field evaluation along B-Rep interface faces. All Dual Contouring vertices snap to exact B-Rep trim curves.

**Case 6 — Non-manifold pinch.** Resolution: after every B-Rep operation, count incident faces per directed half-edge. Any edge with count ≠ 2 triggers `ERR_NON_MANIFOLD_EDGE` before the handle is committed.

**Case 7 — Unallocated field sampling.** Resolution: `field_scalar()` returns `default` with zero gradient for unallocated slots. Out-of-bounds coordinates clamp to boundary voxel (CLAMP\_TO\_EDGE).

## 14. Complete Normative Example

This document exercises all sections of CDML v1.0: symbolic parameters, design assertions, constrained workplane, algebraic sketch with exact parametric circle, SE(3) sweep, differential fillet, implicit gyroid field with simulation coupling, CSG hybrid assembly with B-Rep/implicit collar, simulation bindings, and export targets.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<cdml version="1.0" units="mm" linear_tol="1e-7" angular_tol="1e-11">

  <!-- 1. IMPORTS: material library + fastener parameters -->
  <imports>
    <import src="lib/materials.cdml"/>              <!-- al6061 enters directly -->
    <import src="lib/fasteners.cdml" prefix="fs"/>  <!-- fs.bolt_d, fs.bolt_pcd -->
  </imports>

  <!-- 2. PARAMETERS, FIELD SLOTS, AND DESIGN ASSERTIONS -->
  <defs>
    <var id="flange_w"    value="90.0"  unit="mm" min="60.0" max="150.0"/>
    <var id="flange_h"    value="16.0"  unit="mm" min="8.0"  max="40.0"/>
    <var id="bore_r"      value="15.0"  unit="mm" min="8.0"  max="25.0"/>
    <var id="wall_margin" value="3.0"   unit="mm" min="1.5"  max="6.0"/>
    <var id="fillet_r"    value="4.0"   unit="mm" min="0.5"  max="10.0"/>
    <var id="period"      value="9.0"   unit="mm"/>

    <expr id="half_w"   expr="flange_w / 2"/>
    <expr id="infill_r" expr="bore_r + wall_margin"/>

    <!-- Field slot: FEA stress written by external extension after tessellation -->
    <field-slot id="stress_field" slot="0"
                semantic="stress"
                grid-x="64" grid-y="64" grid-z="24"
                default="40.0"/>

    <assert id="bore_clearance"
      expr="half_w - bore_r - wall_margin - 5.0"
      error="bore plus wall margin exceeds half flange width"/>
    <assert id="wall_positive"
      expr="flange_w * 0.5 - bore_r - wall_margin"
      error="no material between bore and edge"/>
  </defs>

  <body>

    <!-- 3. WORKPLANE AT Z = 0 -->
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

    <!-- 4. SKETCH: SQUARE PROFILE + EXACT CIRCLE BORE -->
    <sketch id="sk_flange" chart="chart_xy" max-iter="100">
      <vars>
        <point2d id="v0" u="-45.0" v="-45.0"/>
        <point2d id="v1" u=" 45.0" v="-45.0"/>
        <point2d id="v2" u=" 45.0" v=" 45.0"/>
        <point2d id="v3" u="-45.0" v=" 45.0"/>
      </vars>

      <wire id="wire_outer" closed="true" role="outer">
        <curve id="seg_bot" degree="1" ctrl="v0 v1" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_rgt" degree="1" ctrl="v1 v2" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_top" degree="1" ctrl="v2 v3" weights="1.0 1.0" knots="0 0 1 1"/>
        <curve id="seg_lft" degree="1" ctrl="v3 v0" weights="1.0 1.0" knots="0 0 1 1"/>
      </wire>

      <!-- Exact circle: parametric equation -->
      <wire id="wire_bore" closed="true" role="hole">
        <param-curve id="c_bore" param="t" domain="0 1"
          u-expr="ref(bore_r) * cos(2 * PI * t)"
          v-expr="ref(bore_r) * sin(2 * PI * t)"/>
      </wire>

      <constraints>
        <residual id="cx"    expr="v0.u + v1.u"/>
        <residual id="cy"    expr="v0.v + v3.v"/>
        <residual id="sym"   expr="v2.u + v3.u"/>
        <residual id="h0"    expr="v1.v - v0.v"/>
        <residual id="h1"    expr="v2.v - v3.v"/>
        <residual id="ortho" expr="dot(v1-v0, v2-v1)"/>
        <residual id="width" expr="norm(v1 - v0) - ref(flange_w)"/>
        <residual id="height" expr="norm(v2 - v1) - ref(flange_w)"/>
      </constraints>
    </sketch>

    <!-- 5. B-REP: LINEAR SWEEP + DIFFERENTIAL FILLET -->
    <brep id="solid_flange" material="al6061">
      <sweep id="sw_extrude" sketch="sk_flange" cap-ends="true">
        <trajectory>
          <translate x="0" y="0" z-expr="ref(flange_h) * v"/>
        </trajectory>
      </sweep>
      <fillet id="fillet_corners"
        edge-predicate="abs(tz) > 0.999 and x^2 + y^2 > ref(infill_r)^2"
        radius-expr="ref(fillet_r)"/>
    </brep>

    <!-- 5a. PROBE: mean field value on the bore faces of the B-Rep carrier.
         Targets solid_flange, not solid_final: solid_flange does not depend
         on solid_gyroid, so there is no dependency cycle (§12.6). -->
    <probe id="mean_bore_stress"
           type="face-mean"
           target="solid_flange"
           face-predicate="from_id('c_bore') and abs(k_gauss) < 1e-9"
           quantity="field_scalar(0, x, y, z, 40.0)"/>

    <!-- 6. IMPLICIT: GYROID INFILL
         t_wall adapts to mean bore stress via probe (step 5a) -->
    <implicit id="solid_gyroid">
      <domain xmin="-45" xmax="45" ymin="-45" ymax="45" zmin="0" zmax="16"
              octree-depth="6" qef-reg="1e-4"/>
      <def name="omega" expr="2 * PI / ref(period)"/>
      <def name="g"
        expr="sin(omega*x)*cos(omega*y) +
              sin(omega*y)*cos(omega*z) +
              sin(omega*z)*cos(omega*x)"/>
      <!-- probe('mean_bore_stress') returns 40.0 until FEA runs,
           then the real mean Von Mises stress in MPa -->
      <def name="t_wall" expr="0.9 + 0.005 * probe('mean_bore_stress')"/>
      <field expr="abs_smooth(g, 1e-4) - (0.5 * omega * t_wall)"/>
    </implicit>

    <!-- 7. IMPLICIT: INFILL ZONE MASK -->
    <implicit id="solid_mask">
      <domain xmin="-45" xmax="45" ymin="-45" ymax="45" zmin="0" zmax="16"/>
      <def name="r"     expr="sqrt(x^2 + y^2)"/>
      <def name="d_box"
        expr="r_intersect(
                abs_smooth(x, 1e-3) - (ref(half_w) - ref(wall_margin)),
                abs_smooth(y, 1e-3) - (ref(half_w) - ref(wall_margin)))"/>
      <def name="d_z"
        expr="abs_smooth(z - ref(flange_h)*0.5, 1e-3)
              - (ref(flange_h)*0.5 - ref(wall_margin))"/>
      <def name="d_in" expr="ref(infill_r) - r"/>
      <field expr="r_intersect(r_intersect(d_box, d_z), d_in)"/>
    </implicit>

    <!-- 8. CSG: HYBRID BOOLEAN ASSEMBLY -->
    <csg id="solid_final">
      <boolean id="hollow_shell" op="subtract"
        left="solid_flange" right="solid_mask"/>
      <boolean id="lattice_core" op="intersect"
        left="solid_mask" right="solid_gyroid"/>
      <boolean id="assembly" op="union"
        left="hollow_shell" right="lattice_core"
        preserve-brep-tags="true" collar-tol="1e-6"/>
    </csg>

    <!-- 9. PROBES: geometry and field queries
         Nothing upstream reads these, so targeting solid_final is acyclic. -->

    <!-- Peak stress on fillet faces (post-FEA) -->
    <probe id="max_fillet_stress"
           type="face-max"
           target="solid_final"
           face-predicate="abs(k_gauss) > 1e-6"
           quantity="field_scalar(0, x, y, z, 40.0)"/>

    <!-- Total enclosed volume (pure geometry, no FEA needed) -->
    <probe id="housing_volume"
           type="volume"
           target="solid_final"/>

    <!-- Design assertions that reference probe results -->
    <assert id="stress_limit"
      expr="200.0 - probe('max_fillet_stress')"
      error="fillet stress exceeds 200 MPa yield margin"/>

    <!-- 10. BOLT HOLE: sketch on chart_xy, swept through the flange, then patterned.
         The circle is an explicit r(t), so the sketch has no unknowns (N = 0, DOF = 0). -->
    <sketch id="sk_bolt" chart="chart_xy">
      <wire id="wire_bolt" closed="true" role="outer">
        <param-curve id="c_bolt_profile" param="t" domain="0 1"
          u-expr="ref(fs.bolt_pcd) + ref(fs.bolt_d)/2 * cos(2*PI*t)"
          v-expr="ref(fs.bolt_d)/2 * sin(2*PI*t)"/>
      </wire>
    </sketch>

    <brep id="solid_bolt_hole">
      <sweep id="sw_bolt" sketch="sk_bolt" cap-ends="true">
        <trajectory>
          <translate x="0" y="0" z-expr="ref(flange_h) * v"/>
        </trajectory>
      </sweep>
    </brep>

    <repeat id="bolt_pattern" count="4" ref="solid_bolt_hole">
      <transform>
        <rotate axis="0 0 1" angle-expr="PI/2 * i"/>
      </transform>
    </repeat>

    <!-- 11. COMPOSE: SEMANTIC ROLE ASSIGNMENT -->
    <compose id="housing">
      <layer ref="solid_final"  role="shell"/>
      <layer ref="bolt_pattern" role="void"/>
    </compose>

  </body>

  <!-- 12. EXPORT TARGETS -->
  <exports>
    <tessellate target="solid_final" chord-tol="0.02" angle-tol="0.05"/>
    <step        target="solid_flange" schema="AP214"/>
    <stl         target="solid_final"  binary="true"/>
  </exports>

</cdml>
```

### 14.1 Coverage map

| Section | Element in example | What it tests |
| --- | --- | --- |
| §2a | `<imports>` × 2 with `prefix=` | Parse-time namespace merge, prefix rewriting, `ref(fs.bolt_pcd)` |
| §3 | `<var>`, `<expr>`, `<assert>`, `<field-slot>` | Parameter DAG, derived expressions, field slot in `<defs>`, pre-geometry assertions |
| §5 | `<chart>` with 3 residuals | Constrained workplane, orthonormal frame from equations |
| §6 | `<sketch>`, `<param-curve id="c_bore">` | QR rank-reveal solver, exact circle, wire role assignment, zero-variable sketch (sk\_bolt) |
| §7 | `<sweep>`, `<fillet>` with `edge-predicate` | SE(3) linear trajectory over outer + hole profile (sketch=), differential predicate edge selection |
| §8 | `solid_gyroid` with `<def>` and `probe('mean_bore_stress')` | Gyroid field equation, probe result fed back into field geometry (acyclic: probe targets solid\_flange) |
| §8 | `solid_mask` with `r_intersect` / `abs_smooth` | R-function field composition for C¹ domain boundaries |
| §9 | `<csg>`, `<boolean>` × 3 | Lazy B-Rep/implicit tree, collar tolerance, tag preservation |
| §10 | `preserve-brep-tags`, `from_id('c_bore')` | Stable `TopoId` across hybrid boolean boundary |
| §11 | `<compose>`, `<repeat>` with `ref(fs.bolt_pcd)` | Semantic roles, bolt hole as chart-anchored sketch + sweep, pattern macro, imported parameter reference |
| §12 | `<probe>` × 3, `<assert>` referencing `probe()` | Geometric and field queries, post-FEA assertion, lazy probe evaluation |
| §13 | `<assert>` × 3 total, error code paths | Pre-geometry and post-probe validation, deterministic failure payloads |
| §14.1 | `<step>`, `<stl>`, `<tessellate>` | Multi-target export from a single hybrid solid |
