# OpenCAD Design System — Executable Engineering Document & Zero-Box Architecture

> **Design Philosophy:** OpenCAD is fundamentally an **executable engineering document**—merging precision **LaTeX academic typography** with the **Zero-Box floating canvas architecture** of `slicer`. It eliminates container noise through four strict invariants:
> 1. **Zero-Box Passive Layer & Padded Surface Active Layer:** Passive readouts (`#info` telemetry, section labels, hover probes, equations, and diagram nodes) float on plain background with **zero boxes, zero borders, and zero cards**. High-action or highly connected interactive clusters (`lil-gui` parameter controller, side tool dock, and the CDML code editor) use **generous negative space (padding + margin offset)** paired with **a single subtle surface (or outline)** for clear visual differentiation without cognitive overload.
> 2. **One Single Accent Hue (Cobalt Azure, `Hue = 212°`, in 3 Shades Only):** Chosen at the optical midpoint between Aqua Blue (`200°`) and Cobalt Blue (`215°`)—the historical hue of blueprint cyanotype ink, LaTeX academic links, and sci-fi CAD instrumentation. All UI accents derive from this single hue varied strictly by saturation and lightness (`#0C71E4`, `#0A50A8`, `#5AA9FF`).
> 3. **Matplotlib `plasma` Colormap for 2D & 3D Quantitative Heatmaps:** All continuous physical fields (FEM thermal distributions, stress fields, and implicit field slices) use the perceptually uniform **Matplotlib `plasma` colormap** (`#0D0887 → #7E03A8 → #CC4778 → #F89540 → #F0F921`), calibrated in sRGB space so 3D WebGL meshes and 2D contour plots match pixel-for-pixel.
> 4. **One Single Typeface Family (`IBM Plex Mono`):** The entire interface, code editor, telemetry HUD, and technical diagrams use **one font family (`IBM Plex Mono`)**, establishing visual hierarchy strictly through **weight** (`300`, `400`, `500`, `600`, `700`), **size**, and **letter-spacing**. (Only standalone $\LaTeX$ math expressions retain standard Computer Modern / STIX math glyphs.)

---

## 1. The High-Action vs. Passive Component Rule (`slicer` Architecture)

Every border, box, or surface must justify its cognitive cost. We divide all visual elements into two categories:

### 1.1 Passive & Read-Only Elements — Zero Boxes, Zero Borders, Zero Surfaces
- **Bottom-Right Telemetry (`#info` / `.viewport-telemetry`)**: Right-aligned monospace text (`text-align: right; pointer-events: none; background: transparent; border: none;`) floating at `bottom: 20px; right: 20px`.
- **Viewport Labels & Hover Probes (`.pane-pill`, `.fem-probe-pill`, `.thermal-legend`)**: Floating directly on the canvas with zero pill backgrounds or borders.
- **Diagrams, Figures & Equations**: Zero enclosing rectangles around text nodes or equations. The diagram structure is communicated purely through whitespace, alignment, vector arrows, and typographic weight.

### 1.2 Rule of Thumb for High-Action & Highly-Connected Components — Negative Space + Subtle Surface
> **Rule of Thumb:** For **high-action or highly connected interactive clusters** (components where the user actively clicks, drags sliders, or edits code), always include **generous negative space (internal padding + external margin offset)** together with **a single unified surface (or subtle outline)**—never both, and never nested boxes inside—to differentiate the action zone from the viewport canvas without visual or cognitive overload.

1. **Side Action Dock (`.viewport-dock` / `nav`)**:
   - Positioned at `left: 20px; top: 50dvh; transform: translateY(-50%)`.
   - Uses a single soft translucent surface (`background: rgba(var(--surface-rgb), 0.86); backdrop-filter: blur(12px); border: none; border-radius: 10px;`) with generous negative-space padding (`padding: 10px 8px; gap: 8px;`).
   - Individual `.dock-btn` icons inside the dock have **zero borders and zero boxes** (`background: transparent; border: none;`), signaling active state purely via `--accent` (`#0C71E4`).
2. **Parameter Controller (`lil-gui.root` / `.lil-controller.root`)**:
   - Positioned at `top: 20px; right: 20px`.
   - Uses the same unified translucent surface (`background: rgba(var(--surface-rgb), 0.86); backdrop-filter: blur(12px); border: none; border-radius: 10px;`) with generous internal padding (`padding: 12px 14px;`) and zero nested folder or controller borders.
3. **Executable Document Code Editor (`#code-pane`)**:
   - Uses a unified calm document surface (`background: var(--surface);` — `#F7F7F8` in light mode, `#141417` in dark mode) with generous negative-space padding (`padding: 12px 16px` header, `12px 16px` editor gutter/body, `8px 16px` status bar) and zero nested boxes around status bars or tab headers.

---

## 2. Color System: One Single Accent Hue (`Hue = 212°` Cobalt Azure) + Matplotlib `plasma`

### 2.1 Why `Hue = 212°` (Cobalt Azure) is the Optimum CAD Hue
CAD is an executable technical document. The optimum sits between **Aqua Blue (`200°`)** and **Cobalt Blue (`215°`)**, at **`Hue = 212°` (Cobalt Azure)**:
- **The colour of technical documents:** Blueprint ink, hyperlinks, and drafting-pen blue all live at `210°–215°`. Readers already read this hue as "linked, editable, engineered".
- **Bright, not muddy:** Teal (`172°–190°`) has to go dark (`L ≈ 28%`) to pass WCAG on white, which makes it look grey-green. At `212°` the core shade passes AA at `L = 47%` with `S = 90%`, so it stays bright and saturated.
- **Calm for long reading:** Unlike red or orange, blue does not trigger alarm. It stays clearly chromatic against charcoal and paper.
- **No clash with the heatmap:** `plasma` runs indigo → magenta → yellow. A clean azure accent does not collide with any warm heatmap stop.
- **Accessible across modes:** `4.67:1` (AA) core on white, `7.70:1` (AAA) deep shade on white, `8.02:1` (AAA) soft shade on dark `#0A0B0D`. All three keep the same hue; only saturation and lightness change.

> **Rule:** `--accent` (`#0C71E4`) is the brightest AA-safe shade at `212°`. Use it for active state, focus, and one focal element per view. Use `--accent-deep` (`#0A50A8`) for small text and numbers. Use `--accent-soft` (`#5AA9FF`) only on dark backgrounds.

| Token | Hex | HSL | RGB | Contrast (vs. `#FFFFFF`) | Role |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`--paper`** | `#FFFFFF` | `hsl(0, 0%, 100%)` | `255, 255, 255` | `1.00 : 1` | Primary viewport canvas & figure background |
| **`--surface`** | `#F7F7F8` | `hsl(240, 5%, 97%)` | `247, 247, 248` | `1.06 : 1` | Code editor (`#code-pane`), `lil-gui`, and side dock surface |
| **`--surface-2`** | `#EFEFF1` | `hsl(240, 6%, 94%)` | `239, 239, 241` | `1.14 : 1` | Slider tracks & input field wells |
| **`--ink`** | `#18181B` | `hsl(240, 6%, 10%)` | `24, 24, 27` | **`17.80 : 1` (AAA)** | Primary typography, boundary contours, equation ink |
| **`--ink-2`** | `#52525B` | `hsl(240, 5%, 34%)` | `82, 82, 91` | **`7.43 : 1` (AAA)** | Secondary telemetry, parameter labels, dimension leaders |
| **`--ink-3`** | `#71717A` | `hsl(240, 4%, 46%)` | `113, 113, 122` | **`4.62 : 1` (AA)** | Muted metadata, inactive dock icons, grid captions |
| **`--line`** | `#E4E4E7` | `hsl(240, 6%, 90%)` | `228, 228, 231` | — | Structural 1px canvas split hairline |
| **`--accent`** | **`#0C71E4`** | **`hsl(212, 90%, 47%)`** | `12, 113, 228` | **`4.67 : 1` (AA)** | **Shade 1 (Core Cobalt Azure):** Active dock icon, slider fill, primary curve |
| **`--accent-deep`** | **`#0A50A8`** | **`hsl(213, 89%, 35%)`** | `7, 78, 92` | **`7.70 : 1` (AAA)** | **Shade 2 (Deep Cobalt):** Numeric readouts, pressed state, key emphasis |
| **`--accent-soft`** | **`#5AA9FF`** | **`hsl(211, 100%, 68%)`** | `34, 184, 207` | **`8.02 : 1` (vs. `#0A0B0D`)** | **Shade 3 (Soft Azure):** Dark-mode primary accent, highlight halo |

### 2.2 Matplotlib `plasma` Colormap for Quantitative 2D & 3D Heatmaps
To ensure instant scientific recognition and perceptual uniformity across both 2D triangular FEM meshes and 3D B-Rep surface projections, all heatmaps use the exact **Matplotlib `plasma`** colormap (`matplotlib.cm.plasma`), calibrated in sRGB so 3D and 2D rendered colors match closely:

| Normalized Scalar $t$ | Token | Hex | sRGB Tuple | Physical Meaning |
| :--- | :--- | :--- | :--- | :--- |
| **`0.00` (Min)** | `--cmap-0` | `#0D0887` | `(13, 8, 135)` | Minimum field intensity / heat sink ($T_{\min}$) |
| **`0.25`** | `--cmap-25` | `#7E03A8` | `(126, 3, 168)` | Lower-quartile transition |
| **`0.50` (Mid)** | `--cmap-50` | `#CC4778` | `(204, 71, 120)` | Mid-range gradient |
| **`0.75`** | `--cmap-75` | `#F89540` | `(248, 149, 64)` | Upper-quartile gradient |
| **`1.00` (Max)** | `--cmap-100` | `#F0F921` | `(240, 249, 33)` | Peak field intensity / heat source ($T_{\max}$) |

> **3D/2D Color-Matching Requirement:** Because Three.js `WebGLRenderer` expects vertex colors in linear-sRGB space and applies output gamma encoding (`SRGBColorSpace`), 3D vertex colors sampled from `plasmaRGB(t)` must be converted via `srgbToLinear(c)` before writing to `BufferAttribute`, and shaded with unlit/balanced normal weighting (`0.94 + 0.06 * nz`) so the 3D surface colors match the 2D HTML5 Canvas colors within $\Delta E < 1.5$.

---

## 3. Typography: One Typeface Family (`IBM Plex Mono`)

All visual hierarchy is achieved within **`IBM Plex Mono`** through **font-weight**, **font-size**, and **letter-spacing**:

```css
:root {
  --font-mono: 'IBM Plex Mono', ui-monospace, 'SFMono-Regular', Menlo, Consolas, monospace;
}
```

| Role | Weight | Size | Letter-Spacing | Color | Usage |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Cover / Hero Headline** | `700` (Bold) | `38px – 52px` | `-0.03em` | `--ink` (`#18181B`) | Primary title on covers and posters |
| **Strategic Highlight** | `600` (SemiBold) | `14px – 18px` | `+0.08em` (Uppercase) | `--accent` (`#0C71E4`) | Key architectural differentiator (`ONE MATH CORE`) |
| **Section / Dialog Header** | `600` (SemiBold) | `12px – 14px` | `+0.04em` (Uppercase) | `--ink` (`#18181B`) | `lil-gui` title, modal header, telemetry brand |
| **CDML Code & Values** | `500` (Medium) | `11.5px – 12.5px` | `0em` (`tabular-nums`) | `--ink` / `--accent-deep` | Code editor, numeric inputs, equation callouts |
| **Body & Diagram Labels** | `400` (Regular) | `11px – 12px` | `0em` | `--ink-2` (`#52525B`) | Diagram node subtitles, documentation copy |
| **Passive Telemetry** | `300` (Light) | `10.5px – 11px` | `+0.02em` (`tabular-nums`) | `--ink-2` / `--ink-3` | Bottom-right `#info` stats, colorbar ticks, hover probes |

---

## 4. Strategic Positioning & Simple Wording

1. **Simple, Direct Verbs**: Always prefer direct engineering verbs—use **"Merging"** instead of `"Unifying"`, **"Zero-Copy"** instead of `"Harmonized"`, and **"Exact"** instead of `"Sophisticated"`.
2. **Strategic Highlight (`ONE MATH CORE` / `B-REP · CSG · IMPLICIT`)**: Do not lead covers or brand graphics with file-size metrics (`925 KB`). Highlight OpenCAD's architectural moat:
   - **`ONE MATH CORE`**
   - **`B-REP · CSG · IMPLICIT · C-ABI`**
   - **Merging exact B-Rep topology, Rvachev $C^1$ CSG, and implicit TPMS fields in a single deterministic Zig/WASM kernel.**

---

## 5. Pre-Commit Design Verification Checklist

- [ ] **High-Action Negative Space & Surface Rule**: Do high-action components (`lil-gui`, `.viewport-dock`, `#code-pane`) have generous internal padding and a single subtle translucent/tinted surface (`#F7F7F8`), while passive readouts (`#info`, `.pane-pill`, diagram nodes, equations) have zero boxes and zero borders?
- [ ] **Single Accent Hue (`Hue = 212°` Cobalt Azure)**: Are all UI accents restricted to the 3 shades of Cobalt Azure (`#0C71E4`, `#0A50A8`, `#5AA9FF`)?
- [ ] **Matched 2D & 3D Matplotlib `plasma` Heatmap**: Do both 2D and 3D thermal viewports use the exact Matplotlib `plasma` colormap (`#0D0887 → #7E03A8 → #CC4778 → #F89540 → #F0F921`) with sRGB-to-linear compensation so 3D and 2D colors match closely?
- [ ] **Single Font Family**: Is `IBM Plex Mono` the sole font family across UI, covers, and diagrams (with weight `300`–`700`, size, and spacing creating all hierarchy)?
