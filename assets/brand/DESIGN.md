# OpenCAD Design System

## 1. Design Principles

1. **Monograph & Paper Surface:** Grounded in pure typeset white, neutral archival gray for code/inspector panels, and true black ink with `1px` booktabs-style hairlines. No decorative cream tints or heavy colored chrome — every surface comes from a token, never a one-off hex value.
2. **Data Owns the Color:** UI chrome is >90% achromatic. Saturated color is reserved exclusively for physical scalar fields (FEM temperature, Von Mises stress, curvature), Cartesian axes, and solver diagnostics — never competing with the simulation. Chrome, semantics, and axes are separate token families even where values currently sit close together, so a change to one never silently changes another.
3. **LaTeX Typography Hierarchy:** Pairs academic serif for titles, modal prose, and governing equations with slashed-zero tabular monospace for CDML code, residuals, and telemetry. A single grotesque sans carries all UI labels. See §3.2 for the pairing rules that keep this from degrading into a mismatched typeface collision.
4. **Physical Graphite Dark Mode:** Dark viewport sessions use matte carbon graphite and plaster white, inspired by studio photography of 3D-printed prototypes — zero tinted blue-black gradients. Every token family has a verified dark-mode counterpart; nothing is light-only.
5. **Viewport-First & Publication-Ready:** The 3D/2D canvas occupies `100%` of the stage (`100vw × 100dvh` or full flex remainder) so any viewport screenshot drops directly into an arXiv/JOSS LaTeX paper without background editing.
6. **Spacing and Rhythm are Systematic:** All padding, gaps, and offsets are drawn from the `--space-*` scale (§2.4). No ad-hoc pixel values in component rules.
7. **Accent Color Budget — 15% Ceiling:** `--accent` (in any tint) may cover **at most 15% of the visible area** of any single visual — a UI screen, a poster, a flyer, or a social post (§8). This is a hard ceiling, not a target: most layouts should land near 5–10%, leaving headroom so accent never competes with the scalar-field and semantic colors that Principle #2 already reserves for data. See §7 for how this budget relates to the ≤10% chrome allowance.

---

## 2. Color System — Named Primitives → Semantic Roles

Every color in this system is defined once, by name, in §2.1 or §2.2. Nothing in §2.3 onward, and nothing in §4–§8, ever hardcodes a hex value — each semantic token (`--surface`, `--ink`, `--accent`, `--state-*`, `--axis-*`, shadows, colormaps) just **points to** a named primitive. Change a primitive's value in one place and every semantic token, every component, and every exported asset that references it updates together.

### 2.1 Primitive Palette — Light

```css
:root {
  /* Paper & archival surfaces */
  --color-paper-white:      #FFFFFF;
  --color-archive-100:      #F6F6F6;
  --color-archive-200:      #ECECEC;
  --color-archive-300:      #E5E5E5;

  /* Ink */
  --color-typeset-black:    #111111;
  --color-graphite-ink:     #404040;
  --color-graphite-mute:    #737373;
  --color-hairline-gray:    #D4D4D4;

  /* Accent (restrained academic hyperref blue) */
  --color-hyperref-blue:    #1B3B8C;

  /* Semantic state family — its own hue ladder, not shades of accent */
  --color-forest-green:     #14532D; /* nominal */
  --color-amber-ochre:      #92400E; /* caution */
  --color-crimson:          #991B1B; /* fault */
  --color-neutral-mute:     #737373; /* offline — shares a value with --color-graphite-mute by coincidence, named separately so the two can diverge later */
  --color-linked-blue:      #2E4E9E; /* linked/selection — near --color-hyperref-blue but its own primitive */

  /* Axis triad — each its own primitive, not reused from accent or state */
  --color-axis-red:         #B91C1C;
  --color-axis-green:       #15803D;
  --color-axis-cobalt:      #26418F;

  /* Thermal colormap ramp */
  --color-thermal-deep-blue:#1D3557;
  --color-thermal-teal:     #2A9D8F;
  --color-thermal-gold:     #E9C46A;
  --color-thermal-orange:   #F4A261;
  --color-thermal-scarlet:  #C1121F;

  /* Diverging colormap ramp */
  --color-diverging-blue:   #1D4E89;
  --color-diverging-cream:  #F5F0E8;
  --color-diverging-red:    #B3261E;
}
```

### 2.2 Primitive Palette — Dark

A parallel, independently named set — dark mode is not "light mode with opacity," it's its own calibrated palette, lightened/desaturated to hold **WCAG AA (≥4.5:1)** against carbon.

```css
:root {
  /* Carbon surfaces */
  --color-carbon-black:     #161615;
  --color-carbon-100:       #1F1F1E;
  --color-carbon-200:       #2A2A28;
  --color-carbon-300:       #353532;

  /* Plaster ink */
  --color-plaster-white:    #F4F4F2;
  --color-plaster-mid:      #C7C7C2;
  --color-plaster-mute:     #8A8A84;
  --color-carbon-hairline:  #333330;

  /* Accent on carbon */
  --color-sky-blue:         #6B93F5;

  /* Semantic state family on carbon */
  --color-mint-green:       #4ADE80;
  --color-sun-amber:        #FBBF24;
  --color-coral-red:        #F87171;

  /* Axis triad on carbon */
  --color-ember-red:        #EF5350;
  /* --color-mint-green doubles as axis-green on carbon — intentional reuse, both read as "go" */
  /* --color-sky-blue doubles as axis-cobalt on carbon */

  /* Thermal ramp on carbon */
  --color-thermal-deep-blue-dark: #3E6EA8;
  --color-thermal-teal-dark:      #4FC3B3;
  --color-thermal-scarlet-dark:   #E5484D;

  /* Diverging ramp on carbon */
  --color-diverging-blue-dark:    #5A8FD6;
  --color-diverging-red-dark:     #E5484D;
}
```

### 2.3 Semantic Tokens — reference primitives only

```css
:root {
  /* Surfaces */
  --paper:            var(--color-paper-white);
  --surface:          var(--color-archive-100);
  --surface-2:        var(--color-archive-200);
  --surface-hover:    var(--color-archive-300);
  --surface-overlay:  rgba(246, 246, 246, 0.94); /* alpha wrap of --color-archive-100 */

  /* Ink */
  --ink:              var(--color-typeset-black);
  --ink-2:            var(--color-graphite-ink);
  --ink-3:            var(--color-graphite-mute);
  --ink-inverse:      var(--color-paper-white);
  --line:             var(--color-hairline-gray);
  --line-subtle:      rgba(17, 17, 17, 0.07);     /* alpha wrap of --color-typeset-black */
  --line-strong:      var(--color-typeset-black);

  /* Accent */
  --accent:           var(--color-hyperref-blue);
  --accent-subtle:    rgba(27, 59, 140, 0.08);    /* alpha wrap of --color-hyperref-blue */
  --accent-ink:       var(--color-paper-white);

  /* Semantic solver/kernel states */
  --state-nominal:    var(--color-forest-green);
  --state-caution:    var(--color-amber-ochre);
  --state-fault:      var(--color-crimson);
  --state-offline:    var(--color-neutral-mute);
  --state-linked:     var(--color-linked-blue);

  /* Axis triad */
  --axis-x:           var(--color-axis-red);
  --axis-y:           var(--color-axis-green);
  --axis-z:           var(--color-axis-cobalt);

  /* Scalar-field colormaps */
  --cmap-thermal-0:    var(--color-thermal-deep-blue);
  --cmap-thermal-25:   var(--color-thermal-teal);
  --cmap-thermal-50:   var(--color-thermal-gold);
  --cmap-thermal-75:   var(--color-thermal-orange);
  --cmap-thermal-100:  var(--color-thermal-scarlet);
  --cmap-diverging-neg: var(--color-diverging-blue);
  --cmap-diverging-mid: var(--color-diverging-cream);
  --cmap-diverging-pos: var(--color-diverging-red);

  /* Elevation (ink-derived, so it re-tints automatically with --ink) */
  --shadow-dock:  0 1px 3px rgba(17, 17, 17, 0.12);
  --shadow-modal: 0 8px 24px rgba(17, 17, 17, 0.16);

  /* ISO 128 technical line weights (not colors, kept here for completeness) */
  --stroke-contour: 1.6px;
  --stroke-mesh:    0.65px;
  --stroke-axis:    0.9px;
  --stroke-hidden:  0.85px;

  /* Typography */
  --font-serif: 'STIX Two Text', 'CMU Serif', 'Latin Modern Roman', Georgia, serif;
  --font-sans:  'IBM Plex Sans', 'Inter', system-ui, -apple-system, sans-serif;
  --font-mono:  'IBM Plex Mono', 'JetBrains Mono', 'CMU Typewriter Text', ui-monospace, monospace;

  /* Radii */
  --radius-none:  0px;
  --radius-sm:    2px;
  --radius-md:    4px;
  --radius-sheet: 8px;

  /* Motion */
  --ease-standard: cubic-bezier(0.2, 0, 0, 1);
  --duration-fast: 100ms;
  --duration-base: 160ms;

  /* Z-index */
  --z-canvas: 0;
  --z-hud: 90;
  --z-dock: 100;
  --z-inspector: 110;
  --z-modal-backdrop: 200;
  --z-modal: 210;
}
```

Dark mode **only repoints the semantic layer to the dark primitive set** in §2.2 — it never introduces a new hex value of its own:

```css
[data-theme="dark"] {
  --paper:           var(--color-carbon-black);
  --surface:         var(--color-carbon-100);
  --surface-2:       var(--color-carbon-200);
  --surface-hover:   var(--color-carbon-300);
  --surface-overlay: rgba(31, 31, 30, 0.94);

  --ink:         var(--color-plaster-white);
  --ink-2:       var(--color-plaster-mid);
  --ink-3:       var(--color-plaster-mute);
  --ink-inverse: var(--color-carbon-black);
  --line:        var(--color-carbon-hairline);
  --line-subtle: rgba(244, 244, 242, 0.08);
  --line-strong: var(--color-plaster-white);

  --accent:        var(--color-sky-blue);
  --accent-subtle: rgba(107, 147, 245, 0.14);
  --accent-ink:    var(--color-carbon-black);

  --state-nominal: var(--color-mint-green);
  --state-caution: var(--color-sun-amber);
  --state-fault:   var(--color-coral-red);
  --state-offline: var(--color-plaster-mute);
  --state-linked:  var(--color-sky-blue);

  --axis-x: var(--color-ember-red);
  --axis-y: var(--color-mint-green);
  --axis-z: var(--color-sky-blue);

  --cmap-thermal-0:   var(--color-thermal-deep-blue-dark);
  --cmap-thermal-25:  var(--color-thermal-teal-dark);
  --cmap-thermal-50:  var(--color-thermal-gold);    /* midpoint unchanged by design */
  --cmap-thermal-75:  var(--color-thermal-orange);  /* midpoint unchanged by design */
  --cmap-thermal-100: var(--color-thermal-scarlet-dark);
  --cmap-diverging-neg: var(--color-diverging-blue-dark);
  --cmap-diverging-mid: var(--color-carbon-black);  /* midpoint matches dark paper, not light cream */
  --cmap-diverging-pos: var(--color-diverging-red-dark);

  --shadow-dock:  0 1px 3px rgba(0, 0, 0, 0.4);
  --shadow-modal: 0 8px 24px rgba(0, 0, 0, 0.5);
}
```

### 2.4 Spacing Scale

```css
:root {
  --space-1: 2px;
  --space-2: 4px;
  --space-3: 8px;
  --space-4: 12px;
  --space-5: 16px;
  --space-6: 24px;
  --space-7: 32px;
}
```

---

## 3. Typography

### 3.1 Scale

| Role | Font Family | Size | Weight | Line Height | Usage |
| --- | --- | --- | --- | --- | --- |
| **Title / Monograph Header** | `--font-serif` | `15px`–`20px` | `700` | `1.3` | Modal headings, figure titles, workshop/paper headers |
| **Governing Math** | `--font-serif` | `13px`–`15px` | `400` italic | `1.5` | Equations (`∫ w(x) R(x) dΩ = 0`, `{f} = [C]{ψ}{Δx}`, `S(u,v)`) |
| **UI Labels & Prose** | `--font-sans` | `12px`–`13px` | `400`–`600` | `1.4` | Modal descriptions, button tooltips, documentation |
| **Code / Telemetry / Controls** | `--font-mono` | `11px`–`12px` | `400`–`600` | `1.4`, `tabular-nums` | CDML editor, `lil-gui` sliders, dimensions, `TopoId`, FPS |

### 3.2 Pairing Rules — what two families together are never allowed to do

Three families (`--font-serif`, `--font-sans`, `--font-mono`) is already the ceiling; the risk is pairing two of them badly within the same view, not adding a fourth. Each rule names the specific collision and why it reads as a mistake rather than intentional hierarchy:

1. **Never pair two serifs, or two sans, as if they were different roles.** A fallback inside one stack (e.g. `CMU Serif` standing in for `STIX Two Text`) is a substitution, not a second typeface in play. Introducing a *different* serif or sans family anywhere for "variety" is the most common bad pairing: two faces from the same classification compete for the same job instead of contrasting, and the mismatch reads as inconsistency, not intent.
2. **Never set `--font-mono` directly inline against `--font-serif` at matching pixel size.** Monospace glyphs run visually larger and heavier than a text serif at the same `px` value, producing a ragged baseline/x-height. Where a CDML identifier or dimension must sit inside serif prose, drop the mono run one step down the §3.1 scale from the surrounding serif size.
3. **Never use `--font-sans` for anything `--font-mono` owns, or vice versa.** Sans for a numeric readout loses `tabular-nums` alignment the moment it's needed in a column; mono for a UI label reads as debug text instead of product copy.
4. **Never widen stroke-weight contrast between two families beyond one step.** A `700` serif title above a `400` sans subtitle is fine; dropping the sans to a `300` light weight, or pushing the serif to a display cut, widens the gap until the pairing looks accidental. Keep sans weight within one step (`400`–`600`) of whatever serif weight sits next to it.
5. **No fourth family, ever, including decorative or script faces.** The serif/sans/mono triad already carries every role this system needs, in §4–§8 alike; a fourth face breaks the "that's clearly OpenCAD" recognition the token system exists to protect.

---

## 4. Component & Control Styling

### 4.1 Dock Buttons (`.dock-btn`)

* Square `32×32px` (`28×28px` mobile), `border-radius: var(--radius-sm)`.
* **Rest:** transparent fill, `1.5px solid var(--ink-2)` stroke, icon in `--ink-2`.
* **Hover:** `--surface-hover` fill, `1px solid var(--line)` stroke.
* **Active (`aria-pressed="true"`):** `--ink` fill, `--ink-inverse` icon.
* **Focus-visible:** `2px solid var(--accent)` outline, `2px` offset.
* **Disabled:** `--ink-3` icon at `50%` opacity, no hover/active state, `cursor: not-allowed`.

### 4.2 `lil-gui` Overrides

```css
.lil-gui.root {
  --background-color: var(--surface) !important;
  --title-background-color: var(--surface-2) !important;
  --title-text-color: var(--ink) !important;
  --text-color: var(--ink-2) !important;
  --widget-color: var(--paper) !important;
  --hover-color: var(--surface-hover) !important;
  --focus-color: var(--accent) !important;
  --number-color: var(--accent) !important;
  --string-color: var(--ink) !important;
  border: 1px solid var(--line) !important;
  border-radius: var(--radius-md) !important;
  font-family: var(--font-mono) !important;
}
```

### 4.3 Brand Mark

* On light paper, render the 4-lobe twisted torus mark in `--ink`.
* On dark graphite, render it in `--ink` — the token flips per-theme automatically; the mark itself never hardcodes a value.

---

## 5. Core Layout & Component Patterns

### 5.1 Studio & Demo Viewport (`#viewport-container` / `#stage-root`)

* **Desktop (`>= 768px`):** Horizontal flex row. Split 3D/2D views or Code + Viewport with a `1px solid var(--line)` hairline divider.
* **Mobile (`< 768px`):** Vertical flex stack with a `1px solid var(--line)` horizontal divider.
* **Breakpoint token:** `--bp-desktop: 768px`.

### 5.2 Left Floating Viewport Dock (`.viewport-dock`)

* Anchored `left: var(--space-4)` (`var(--space-3)` mobile), vertically centered, `z-index: var(--z-dock)`.
* Surface: `var(--surface-overlay)`, `blur(6px)`, `1px solid var(--line)`, `border-radius: var(--radius-md)`, `box-shadow: var(--shadow-dock)`, `padding: var(--space-2)`, `gap: var(--space-2)`.
* Buttons per §4.1. Include only tools tied to the active view (`Code`, `Snapshot`, `Fit`, `Wireframe`, `Params` in Studio; `3D`, `2D`, `Fit`, `Wire`, `Params`, `Info`, `Source` in `feascript-demo.html`).

### 5.3 Floating Parameter Inspector (`.lil-gui.root`)

* Anchored `top/right: var(--space-4)` (`var(--space-3)` mobile, collapsed by default `< 768px`).
* Width: `272px` desktop, `210px` mobile; `max-height: calc(100dvh - 130px)`; `z-index: var(--z-inspector)`.
* Overrides per §4.2. `tabular-nums` enforced on all numeric inputs and `<probe>` monitors.

### 5.4 Engineering Telemetry HUD (`.viewport-telemetry`)

* Anchored `bottom/right: var(--space-4)` (`var(--space-3)` mobile), `z-index: var(--z-hud)`, `pointer-events: none`, right-aligned mono column (`gap: var(--space-1)`).
* 4-line hierarchy: Context Brand → Kernel/Solver Status (dot maps 1:1 to `--state-*`, never `--accent`/`--axis-*`) → Physical Metrics → Discretization & Frame Stats.
* HUD and dock anchor to opposite edges by construction, so neither competes for the same corner at any breakpoint.

### 5.5 Technical Info Modal & Mobile Sheet (`dialog#info-dialog`)

* Native `<dialog closedby="any">`, `rgba(5, 15, 31, 0.38)` backdrop, `z-index: var(--z-modal)` (`--z-modal-backdrop` for the backdrop).
* **Desktop:** centered card, `width: min(680px, calc(100vw - 28px))`, `border-radius: var(--radius-md)`, `1px solid var(--line-strong)`, `box-shadow: var(--shadow-modal)`.
* **Mobile:** bottom sheet, `width: 100vw; max-height: 82dvh; border-radius: var(--radius-sheet) var(--radius-sheet) 0 0`.
* Equation callouts: `--surface-2` background, `2px solid var(--ink-2)` left border, `--font-serif` math (§3.2 rule 2 applies if a mono value sits inside the callout).
* Opens/closes with `var(--duration-base) var(--ease-standard)`.

### 5.6 Scientific Colormaps & Mandatory Scale Bar

* Pair every scalar-field visualization with a Scale Bar (`1px solid var(--line)`, `border-radius: var(--radius-none)`) showing `min`/`mid`/`max` ticks and SI units, built from §2.3's `--cmap-*` tokens.
* **Thermal (default):** `--cmap-thermal-0 → 25 → 50 → 75 → 100`.
* **Sequential / Stress / Curvature:** `Viridis` or `Cividis` (referenced by name, not re-tokenized — already perceptually uniform and colorblind-safe).
* **Diverging / Signed Distance / Residuals:** `--cmap-diverging-neg → mid → pos`, neutral paper centered at `0`.
* Tick labels follow §3.1's Code/Telemetry row.

### 5.7 Publication / Paper Snapshot Mode

* `Snapshot` dock button or `?figure=true`: forces canvas to `--paper` under a **forced light theme** regardless of the active app theme — a carbon-background figure doesn't drop into a LaTeX doc cleanly.
* Hides dock, `lil-gui`, FPS counter; retains optional orientation triad and scalar colorbar.
* Exports `2×`/`300 DPI`-equivalent PNG (SVG for 2D profiles).

### 5.8 Embed Mode (`?embed=true` & `<opencad-viewer>`)

* `100vw × 100dvh` full-bleed. Declarative toggles via URL params / `data-*` attributes.
* Inherits host page's `data-theme` if present; defaults to light/paper otherwise.

### 5.9 Empty, Loading, and Error States

* **Loading:** centered `1px` rotating arc in `--ink-3`, `var(--duration-base)`/revolution. HUD line 2: `LOADING · —`.
* **Empty:** centered mono caption in `--ink-3`: `No geometry loaded`. View-dependent dock buttons disabled per §4.1.
* **Error:** HUD dot → `--state-fault`, line 2 shows the CDML error code. Error color stays in chrome only, never the canvas/axes.

---

## 6. Accessibility Baseline

* **Contrast:** All ink/surface pairings, and every state/axis token against both paper values, meet WCAG AA (4.5:1 body, 3:1 large/icons).
* **Focus:** Every interactive control has a visible `focus-visible` ring in `--accent`.
* **Color independence:** Solver status is always paired with text, never color alone.
* **Motion:** `--duration-*` under 200ms, `--ease-standard`, respects `prefers-reduced-motion: reduce`.

---

## 7. Color Usage Budget (applies everywhere — UI, print, social)

A single rule, stated once, referenced by §1.2, §1.7, and §8 rather than repeated with different numbers in different places:

| Layer | Ceiling | Notes |
| --- | --- | --- |
| **Accent** (`--accent`, i.e. `--color-hyperref-blue` or its dark equivalent) | **15%** of visible area | Per Principle #7. Applies to any single screen, poster, flyer, or post — not averaged across a set. |
| **Semantic state + axis + colormap, combined** | No fixed % — governed by content, not decoration | These are *data*, not decoration (Principle #2), so they're excluded from the chrome ceiling but never used decoratively outside their defined role (status dot, axis line, scalar field). |
| **All saturated color in UI chrome combined** (accent + state + axis, excluding live-data regions like the canvas or a colorbar) | **≤10%** | Keeps Principle #2's ">90% achromatic chrome" literal, not aspirational. |

---

## 8. Collateral & Social Formats — Posters, Flyers, Posts, and Web, One Rule Set

Rather than a separate spec per channel, every format below is the **same grid, type scale, and token system** (§2–§3, §7) poured into a different container. If a layout can't be described purely by changing the four variables in §8.1, it's drifting from the system.

### 8.1 The Four Variables Per Format

| Variable | What it controls |
| --- | --- |
| **Canvas size / aspect ratio** | The only thing that actually changes between a poster and a web banner. |
| **Safe margin** | Always a `--space-*` token, scaled by the same multiplier as the canvas (§8.2) — never a bespoke print margin. |
| **Grid columns** | Derived from aspect ratio: portrait formats run 4 columns, square runs 4, wide/landscape runs 8. |
| **Type scale multiplier** | §3.1's px values are the `1×` (screen/web) reference; print/social formats multiply by a single factor (§8.2) so the serif/sans/mono *ratios* to each other never change, only the absolute size. |

Everything else — which family does which job (§3), the 15% accent ceiling (§7), achromatic-dominant chrome (Principle #2), hairline-weight dividers, sharp (`--radius-sm`/`none`) corners, and brand-mark clear space equal to `2×` the mark's own height on every side — is identical across every format below. A reviewer checking a flyer against this system should be checking the *same* things they'd check on the web app, not a parallel flyer-specific checklist.

### 8.2 Format Reference

| Format | Canvas | Safe Margin | Grid | Type Multiplier | Color Mode |
| --- | --- | --- | --- | --- | --- |
| **Web (app, this system)** | Fluid, `100vw × 100dvh` | `--space-4`–`--space-7` per §5 | Flex-based, not column grid | `1×` (§3.1 as written) | sRGB — tokens used directly |
| **Social Post — Square** | `1080×1080px` (1:1) | `--space-7` × 3 (`96px`) | 4 columns | `3×` | sRGB |
| **Social Post — Portrait** | `1080×1350px` (4:5) | `--space-7` × 3 (`96px`) | 4 columns | `3×` | sRGB |
| **Social Story** | `1080×1920px` (9:16) | `--space-7` × 3 (`96px`), **+120px top/bottom** for platform UI overlap | 4 columns | `3×`–`4×` for the headline only (distance-viewing) | sRGB |
| **Flyer** | `8.5×11in` / A4, 300 DPI | `--space-7` scaled to `0.5in` | 4 columns | `6×`–`8×` (print at arm's length) | Export sRGB, **convert to CMYK before offset print** — `--color-hyperref-blue` and the thermal ramp aren't guaranteed in-gamut; proof before mass print |
| **Poster** | `24×36in`, 150–300 DPI | `--space-7` scaled to `1.5in` | 8 columns (room for a figure + caption column) | `12×`–`16×` (viewed from several feet) | Export sRGB, convert to CMYK, same proofing caveat as Flyer |
| **Article Cover (16:9)** | `1920×1080px` (16:9) | `--space-7` × 3 (`96px`) | 8 columns | `3×` | sRGB — follows §9 Single-Concept & Zero-Decoration laws |

### 8.3 Rules That Hold Across All Formats

1. **Brand mark position is fixed per orientation, not per format.** Bottom-left on anything landscape/fluid (web, poster), top-left or bottom-center on anything portrait (flyer, social portrait/square/story) — one axis-aligned choice, not a re-decision per channel.
2. **Accent budget (§7) is measured on the canvas as shipped**, not on a cropped preview — a square post cropped from a portrait master must be re-checked independently, since cropping can concentrate accent area past 15%.
3. **Typography families never change across formats** — only the multiplier in §8.1 does. A poster titled in anything other than `--font-serif`, or a flyer's price/spec callouts set in anything other than `--font-mono`, is §3.2's rule 1/3 happening in print instead of on screen.
4. **Scalar-field colormaps and axis colors are web/viewport-only.** Posters, flyers, and posts illustrate OpenCAD — they don't render live solver output — so `--cmap-*` and `--axis-*` tokens appear only as a reproduced screenshot (via §5.7 Snapshot Mode) inside the layout, never recolored or reused as the collateral's own decorative palette. This is what stops the thermal ramp from being "borrowed" as a flyer gradient, which would blow the accent/chrome budgets in §7 instantly.
5. **Dark-mode collateral uses the dark primitive set (§2.2) wholesale**, never a manual "looks dark enough" approximation — a dark-themed post swaps to `--color-carbon-black` / `--color-plaster-white` / `--color-sky-blue` exactly as `[data-theme="dark"]` does for the app, so a screenshot taken from the dark-mode app drops into dark collateral without a color mismatch.

---

## 9. Functional Simplicity & Foolproof Simplification Protocol

Every visual artifact, figure, equation render, cover image, UI view, and code module in OpenCAD is governed by **Functional Simplicity**: maximum conceptual clarity with near-zero cognitive load. If an element can be removed without changing the mathematical or functional meaning of the artifact, it **must** be removed.

### 9.1 Core Laws of Functional Simplicity

1. **One Artifact, One Concept (Single-Subject Law):**
   * Every figure, cover, or equation render communicates **exactly one concept**. Never combine a bar chart, an architecture flowchart, and a specification table inside a single image.
   * The reader must grasp the relationship in **under 2 seconds** without reading paragraphs inside the image.
2. **Zero Redundant Titles & Metadata Inside Visuals:**
   * **Never write figure titles, figure numbers (`FIG 1`), file paths, timestamps, author tags, or license strings inside a figure or equation image.**
   * The surrounding document (Markdown heading, figure caption, or article headline) already supplies context. Repeating titles inside the canvas creates visual noise and cognitive duplication.
3. **Plain Background & Zero Decoration by Default:**
   * Default canvas is pure `--paper` (`#FFFFFF` in light mode, `#161615` in dark mode).
   * **No decorative containers:** Do not wrap diagrams or equations in shaded gray cards (`#F6F6F6`), drop-shadow boxes, left accent stripes, rounded badges, or outer framing rectangles unless a boundary represents an actual mathematical domain (e.g., an octree cell $[x_{\min}, x_{\max}]$ or a B-Rep solid boundary).
4. **Equations Are Pure Typography:**
   * An equation image contains **only the typeset mathematical expression** in `--ink` (`#111111`) using `--font-serif` (`STIX Two Text` / math serif) on a plain `--paper` (`#FFFFFF`) background.
   * Zero borders, zero background tint, zero header titles, and zero monospace/Unicode footers.
5. **Drop-In Functional Modularity (Code & Scripts):**
   * In demos and examples, strictly separate **presentation (`styles/*.css`)**, **external dependencies (`<script type="importmap">`)**, and **reusable logic (`js/*.js` ES modules)**.
   * Every script module must export self-contained, drop-in functions or classes with a single responsibility (e.g., WASM memory bridge, geometry converter, PDE solver, or viewport renderer).

### 9.2 The 5-Step Foolproof Simplification & Functionalization Protocol

Apply this deterministic 5-step reduction protocol before creating, reviewing, or shipping any figure, equation, cover, UI screen, or code module:

| Step | Name | Action | Pass / Fail Test |
| :--- | :--- | :--- | :--- |
| **Step 1** | **Isolate the Irreducible Core** | State the artifact's single job in one sentence of $\le 12$ words (e.g., *"Show one SSA tape branching into Dual gradients and Interval octrees"*). | If the sentence requires "and also", split the artifact into two separate figures or modules. |
| **Step 2** | **Strip to Plain Canvas** | Start on a raw `#FFFFFF` (`--paper`) canvas (or empty ES module). Place **only** the primary mathematical/geometric subject (the equation, the curve + vector, the 3D solid, or the 3–5 core flow nodes). | Are there any shaded background cards, outer boxes, or decorative dividers? If yes, delete them. |
| **Step 3** | **Purge Titles & Metadata** | Delete every top header bar, `FIG N` label, subtitle, filename, URL, bullet list, and legend box that duplicates the host document's text. | Does any text remain besides the mathematical symbols or node identifiers required to read the diagram? If yes, delete it. |
| **Step 4** | **Enforce the Token & Color Gate** | Map every remaining stroke and glyph to §2–§3 tokens (`--ink` `#111111` primary, `--ink-2` `#404040` secondary, `--font-serif` for math, `--font-mono` for opcodes/addresses). Reserve `--accent` (`#1B3B8C`) or `--state-nominal` (`#14532D`) strictly for the single focal element ($\le 15\%$ area). | Is chromatic color $> 15\%$ of the canvas or used decoratively? Is a fourth font family present? If yes, revert to `--ink`. |
| **Step 5** | **Execute theDeletion Test (Subtraction Audit)** | Inspect every remaining line, box, label, or helper function one by one and ask: *"If I delete this element, does the core concept break?"* | If the concept is still understood after deleting the element, keep it deleted. Ship only what survives subtraction. |

---

## 10. Brand Assets Inventory (`assets/brand/` & `web-app/public/branding/`)

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
