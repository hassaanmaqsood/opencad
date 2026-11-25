# OpenCAD Design System

## 1. Design Principles

1. **Monograph & Paper Surface:** Grounded in pure typeset white (`#FFFFFF`), neutral archival gray (`#F6F6F6`) for code/inspector panels, and true black ink (`#111111`) with `1px` booktabs-style hairlines (`#D4D4D4`). No decorative cream tints or heavy colored chrome.
2. **Data Owns the Color:** UI chrome is >90% achromatic. Saturated color is reserved exclusively for physical scalar fields (FEM temperature, Von Mises stress, curvature), Cartesian axes, and solver diagnostics—never competing with the simulation.
3. **LaTeX Typography Hierarchy:** Pairs academic serif (`STIX Two Text` / `Computer Modern`) for titles, modal prose, and governing equations with slashed-zero tabular monospace (`IBM Plex Mono` / `JetBrains Mono`) for CDML code, residuals, and telemetry.
4. **Physical Graphite Dark Mode:** Dark viewport sessions use matte carbon graphite (`#161615`) and plaster white (`#F4F4F2`) inspired by physical studio photography of 3D-printed prototypes—zero tinted blue-black gradients.
5. **Viewport-First & Publication-Ready:** The 3D/2D canvas occupies `100%` of the stage (`100vw × 100dvh` or full flex remainder) so any viewport screenshot drops directly into an arXiv/JOSS LaTeX paper without background editing.

---

## 2. CSS Design Tokens (`:root`)

```css
:root {
  /* Surfaces — Pure Research Paper */
  --paper: #FFFFFF;            /* Primary 3D/2D canvas & figure background */
  --surface: #F6F6F6;          /* Code blocks, floating docks, lil-gui panels */
  --surface-2: #ECECEC;        /* Panel headers, folder bars, numeric inputs */
  --surface-hover: #E5E5E5;    /* Hover states */

  /* Ink & Booktabs Borders */
  --ink: #111111;              /* Primary text, math, active solid brand mark */
  --ink-2: #404040;            /* Secondary labels, dock icons */
  --ink-3: #737373;            /* Comments, units, captions, muted telemetry */
  --line: #D4D4D4;             /* 1px structural hairline */
  --line-subtle: rgba(17, 17, 17, 0.07); /* Subtle drafting grid */
  --line-strong: #111111;      /* Booktabs top/bottom rules, active borders */

  /* Restrained Academic Accent (LaTeX hyperref / syntax keyword blue) */
  --accent: #1B3B8C;
  --accent-subtle: rgba(27, 59, 140, 0.08);

  /* Semantic Solver & Kernel Status Vocabulary */
  --state-nominal: #14532D;    /* CDML_OK / SOLVED (DOF = 0) / Manifold */
  --state-caution: #92400E;    /* UNDER / OVER constrained / Iterating */
  --state-fault: #991B1B;      /* ERR_* / CONFLICTING / Assert Violated */
  --state-offline: #737373;    /* Idle / Uninitialized */
  --state-linked: #1B3B8C;     /* Active selection / Linked extension */

  /* Right-Handed Cartesian Axis Triad (Print-Calibrated) */
  --axis-x: #B91C1C;           /* +X Red */
  --axis-y: #15803D;           /* +Y Green */
  --axis-z: #1B3B8C;           /* +Z Cobalt */

  /* ISO 128 Technical Line Weights */
  --stroke-contour: 1.6px;     /* Visible solid edges */
  --stroke-mesh: 0.65px;       /* FEM / Tessellation wireframe */
  --stroke-axis: 0.9px;        /* Centerlines & datum axes */
  --stroke-hidden: 0.85px;     /* Hidden / construction geometry */

  /* Typography */
  --font-serif: 'STIX Two Text', 'CMU Serif', 'Latin Modern Roman', Georgia, serif;
  --font-sans: 'IBM Plex Sans', 'Inter', system-ui, -apple-system, sans-serif;
  --font-mono: 'IBM Plex Mono', 'JetBrains Mono', 'CMU Typewriter Text', ui-monospace, monospace;

  /* Radii — Sharp Academic Geometry */
  --radius-none: 0px;          /* Tables, dividers, colorbars */
  --radius-sm: 2px;            /* Buttons, inputs, tags */
  --radius-md: 4px;            /* Code blocks, floating docks, modals */
  --radius-sheet: 8px;         /* Mobile bottom-sheet top corners only */
}

/* Dark Studio Mode — Carbon Graphite & Plaster */
[data-theme="dark"] {
  --paper: #161615;
  --surface: #1F1F1E;
  --surface-2: #2A2A28;
  --surface-hover: #353532;
  --ink: #F4F4F2;
  --ink-2: #C7C7C2;
  --ink-3: #8A8A84;
  --line: #333330;
  --line-subtle: rgba(244, 244, 242, 0.08);
  --line-strong: #F4F4F2;
  --accent: #6B93F5;
  --accent-subtle: rgba(107, 147, 245, 0.14);
}

```

---

## 3. Typography Scale

| Role | Font Family | Size | Weight | Usage |
| --- | --- | --- | --- | --- |
| **Title / Monograph Header** | `--font-serif` | `15px`–`20px` | `700` | Modal headings, figure titles, workshop/paper headers |
| **Governing Math** | `--font-serif` | `13px`–`15px` | `400` italic | Equations (`∫ w(x) R(x) dΩ = 0`, `{f} = [C]{ψ}{Δx}`, `S(u,v)`) |
| **UI Labels & Prose** | `--font-sans` | `12px`–`13px` | `400`–`600` | Modal descriptions, button tooltips, documentation |
| **Code / Telemetry / Controls** | `--font-mono` | `11px`–`12px` | `400`–`600` | CDML editor, `lil-gui` sliders, dimensions, `TopoId`, FPS |



---

### 3. Quick `lil-gui` & Dock Styling Adjustments for the Paper Look

To make your floating controls look like they belong on top of a LaTeX figure rather than a dark gaming widget:

* **Active Dock Button (`.dock-btn[aria-pressed="true"]`):** Flip from `#0A2351` navy to **`#111111` (Typeset Black)** fill with **`#FFFFFF`** icon stroke—crisp, ink-on-paper contrast.
* **`lil-gui` Overrides:**

```css
  .lil-gui.root {
    --background-color: var(--surface) !important;
    --title-background-color: var(--surface-2) !important;
    --title-text-color: var(--ink) !important;
    --text-color: var(--ink-2) !important;
    --widget-color: var(--paper) !important;
    --hover-color: var(--surface-hover) !important;
    --focus-color: var(--paper) !important;
    --number-color: var(--accent) !important;
    --string-color: var(--ink) !important;
    border: 1px solid var(--line) !important;
    border-radius: var(--radius-md) !important;
    font-family: var(--font-mono) !important;
  }

```

* **Brand Mark Update:** On light paper (`#FFFFFF`), render your 4-lobe twisted torus mark in **`#111111` (Typeset Black)** instead of `#0A2351`, and on dark graphite (`#161615`), render it in **`#F4F4F2` (Plaster White)**.

---

## 4. Core Layout & Component Patterns

### 4.1 Studio & Demo Viewport (`#viewport-container` / `#stage-root`)

* **Desktop (`>= 768px`):** Horizontal flex row (`flex-direction: row`). Split 3D/2D views or Code + Viewport divide cleanly with a `1px solid var(--line)` hairline divider.
* **Mobile (`< 768px`):** Vertical flex stack (`flex-direction: column`) with a `1px solid var(--line)` horizontal divider.

### 4.2 Left Floating Viewport Dock (`.viewport-dock`)

* Anchored `left: 12px` (`8px` on mobile), vertically centered, `z-index: 100`–`120`.
* Surface: `rgba(245, 240, 232, 0.94)` with minimal blur (`blur(6px)`), `1px solid var(--line)`, `border-radius: var(--radius-md)`, `padding: 4px`, `gap: 4px`.
* Square `32×32px` tool buttons (`.dock-btn`), `border-radius: var(--radius-sm)`:
* **Rest:** transparent, `--ink-2` `1.5px` stroke.
* **Hover:** `--surface-hover`, `1px solid var(--line)`.
* **Active (`aria-pressed="true"`):** `--ink-2` (`#0A2351`) fill, `--paper` (`#FAF7F3`) foreground.


* Include only tools directly tied to the active view (`Code`, `Snapshot`, `Fit`, `Wireframe`, `Params` in Studio; `3D`, `2D`, `Fit`, `Wire`, `Params`, `Info`, `Source` in `feascript-demo.html`).

### 4.3 Floating Parameter Inspector (`.lil-gui.root`)

* Anchored `top: 12px; right: 12px` (`top: 8px; right: 8px` on mobile, collapsed by default on `< 768px`).
* Width: `272px` desktop, `210px` mobile; `max-height: calc(100dvh - 130px)`.
* Override `lil-gui` defaults to match `--surface`, `--surface-2`, `--paper` widgets, `--ink-2` numeric values and slider bars, and `--radius-sm` sharp corners.
* Enforce `font-variant-numeric: tabular-nums` on all numeric inputs and read-only `<probe>` monitors.

### 4.4 Engineering Telemetry HUD (`.viewport-telemetry`)

* Anchored `bottom: 12px; right: 12px` (`8px` on mobile), `pointer-events: none`, right-aligned tabular monospace column (`gap: 2px`).
* Strict 4-line hierarchy:
1. **Context Brand** (`OpenCAD` or `OpenCAD × FEAScript`)
2. **Kernel / Solver Status** (`6×6px` status dot + `SOLVED · DOF 0` or `CONVERGED · 14 ms`)
3. **Physical Metrics** (bounding box `64.0 × 64.0 × 19.0 mm`, volume `33,549 mm³`, active `<probe>` values)
4. **Discretization & Frame Stats** (`60 FPS · 9,472 Tri · 4,716 Vert`)



### 4.5 Technical Info Modal & Mobile Sheet (`dialog#info-dialog`)

* Uses native `<dialog closedby="any">` with `rgba(5, 15, 31, 0.38)` backdrop.
* **Desktop:** Centered monograph card (`width: min(680px, calc(100vw - 28px))`, `border-radius: var(--radius-md)`, `1px solid var(--line-strong)`).
* **Mobile (`< 768px`):** Bottom sheet (`width: 100vw; max-height: 82dvh; border-radius: var(--radius-sheet) var(--radius-sheet) 0 0`).
* Supports equation callout blocks (`--surface-2` background, `2px solid var(--ink-2)` left border, `--font-serif` math).

### 4.6 Scientific Colormaps & Mandatory Scale Bar

Whenever a scalar field (temperature, Von Mises stress, signed distance, Gaussian curvature) is visualized, pair it with a compact horizontal or vertical **Scale Bar** (`1px solid var(--line)`, `border-radius: 0px`) displaying `min`, `mid`, `max` ticks and SI units.

* **Thermal (Default — Paper-Harmonized 5-Stop Ramp):**
```
0.00  #1D3557   Coolant / Min
0.25  #2A9D8F
0.50  #E9C46A
0.75  #F4A261
1.00  #C1121F   Heat Source / Max

```


* **Sequential / Stress / Curvature Magnitude:** `Viridis` or `Cividis` (perceptually uniform, grayscale-monotonic, colorblind-safe for journal figures).
* **Diverging / Signed Distance (`F(x) = 0`) & Residuals:** Cool-to-Warm (`#1D4E89` → `#F5F0E8` → `#B3261E`) with neutral paper centered at `0`.

### 4.7 Publication / Paper Snapshot Mode

Triggered via the `Snapshot` dock button (or `?figure=true`):

* Temporarily sets canvas background to `--paper-pure` (`#FFFFFF`) or transparent.
* Hides dock, `lil-gui`, and FPS counter; retains optional bottom-left orientation triad (`X/Y/Z`) and scalar colorbar.
* Exports crisp `2×` / `300 DPI`-equivalent PNG (and SVG for 2D profiles) ready for LaTeX `\includegraphics`.

### 4.8 Embed Mode (`?embed=true` & `<opencad-viewer>`)

* Renders 100% full-bleed viewport (`100vw × 100dvh`).
* Declarative toggles via URL params or `data-*` attributes: `data-gui="false|true"`, `data-gui-vars`, `data-gui-probes`, `data-gui-exports`, `src="<url>.cdml"`.

---

## 5. Brand Assets Inventory (`assets/brand/` & `web-app/public/branding/`)

Canonical brand mark: **4-Lobe Twisted Toroidal Ring** — exact $C_4$-symmetric orthographic projection of OpenCAD's B-Rep $SE(3)$ twisted square-section sweep, supporting 1-color `Fill` ↔ `Edge Outline` toggling from the identical SVG `<path>`.

| Asset | Purpose |
| --- | --- |
| `opencad-logo-fill.svg` / `opencad-logo-outline.svg` / `opencad-logo-toggle.svg` | Canonical 4-lobe twisted torus mark (single-color solid, exact edge outline, and interactive CSS toggle) |
| `opencad-lockup-light.svg` / `opencad-lockup-dark.svg` | Horizontal mark + `OpenCAD` wordmark lockups |
| `opencad-design-system.svg` | Master visual identity, $C_4$ construction grid, and token specification board |
| `opencad-icon-512.png` | 512×512 app icon & manifest asset |
| `opencad-social-og-light.{svg,png}` / `opencad-social-og-dark.{svg,png}` | Open Graph / social preview cards (`1200×630`) |
| `opencad-github-cover-light.{svg,png}` / `opencad-github-cover-dark.{svg,png}` | GitHub repository cover banners |
| `web-app/public/branding/opencad-mark.svg`, `opencad-og.png` | Runtime favicon & OG tags (never rendered inside the 3D viewport) |

