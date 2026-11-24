# OpenCAD Design System (`Cream & Navy`)

Single-source design specification for all OpenCAD web applications (`web-app/` Studio, `<opencad-viewer>` embed, and `feascript-demo.html`).

---

## 1. Design Principles

1. **View-Central Viewport:** The 3D/2D geometry canvas occupies `100%` of the viewport (`100vw × 100dvh` when standalone/embedded, or full flex remainder alongside the collapsible code pane). No marketing headers, hero banners, or logo watermarks inside the 3D canvas.
2. **Light-Theme Paper Surface:** Warm drafting-paper cream (`#FAF7F3`) with deep engineering navy (`#0A2351`) accents and flat, border-defined surfaces (`1px solid #C8C0B4`, zero drop-shadow clutter except floating HUDs).
3. **Color Budget:** Chromatic accents (`#0A2351`, status colors, thermal colormaps) stay strictly bounded below 30% of the UI chrome; structural surfaces remain neutral cream/stone.
4. **Monospace Precision:** Numeric readouts, dimensions, residuals, coordinates, and controls use tabular monospace (`Courier New`) while titles/wordmarks use heavy geometric sans (`Arial Black`).

---

## 2. CSS Design Tokens (`:root`)

Canonical values from [`web-app/src/style.css`](../../web-app/src/style.css):

```css
:root {
  /* Surfaces & Neutrals */
  --paper: #FAF7F3;        /* Primary canvas & viewport background */
  --surface: #F5F0E8;      /* Floating panels, docks, status bars */
  --surface-2: #EDE6DB;    /* Panel headers, folder headers, inputs */
  --surface-hover: #E4DDD0;/* Hover states */

  /* Ink & Borders */
  --ink: #050F1F;          /* Primary body text */
  --ink-2: #0A2351;        /* Navy headings, active controls, telemetry */
  --ink-3: #6B6560;        /* Secondary labels, muted metadata */
  --line: #C8C0B4;         /* 1px structural borders */
  --line-subtle: rgba(10, 35, 81, 0.08);
  --line-strong: #0A2351;

  /* Accent & Five-Tag Semantic Status Vocabulary */
  --accent: #0A2351;
  --accent-subtle: rgba(10, 35, 81, 0.10);
  --state-nominal: #0A5C38; /* OK / Converged / Synced */
  --state-caution: #9A6700; /* Busy / Iterating / Warning */
  --state-fault: #8B1A1A;   /* Error / Diverged / Assert violated */
  --state-offline: #6B6560; /* Idle / Uninitialized */
  --state-linked: #0A2351;  /* Linked / Active focus */

  /* Typography */
  --font-display: 'Arial Black', 'Arial', system-ui, -apple-system, sans-serif;
  --font-sans: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  --font-mono: 'Courier New', ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;

  /* Radii */
  --radius-sm: 4px;
  --radius-md: 6px;
  --radius-lg: 8px;
  --radius-full: 9999px;
}
```

---

## 3. Typography Scale

| Role | Font Family | Size | Weight | Usage |
| :--- | :--- | :--- | :--- | :--- |
| **Display / HUD Brand** | `--font-display` | `11px`–`16px` | `900` | Telemetry brand (`OpenCAD`, `FEAScript × OpenCAD`), modal titles |
| **UI Body / Descriptions** | `--font-sans` | `12px`–`13px` | `400`–`600` | Modal prose, documentation cards |
| **Controls / Telemetry / Code** | `--font-mono` | `10.5px`–`12px` | `400`–`700` | Dock buttons, `lil-gui`, status bars, dimensions, coordinates |

---

## 4. Core Layout & Component Patterns

### 4.1 Studio & Demo Viewport (`#viewport-container` / `#stage-root`)
- **Desktop (`>= 768px`):** Horizontal flex row (`flex-direction: row`). Split 3D/2D views divide `flex: 1 1 0%` with a `1px solid var(--line)` divider.
- **Mobile (`< 768px`):** Vertical flex stack (`flex-direction: column`) with `1px solid var(--line)` horizontal divider.

### 4.2 Left Floating Viewport Dock (`.viewport-dock`)
- Anchored `left: 14px` (`8px` on mobile), vertically centered (`top: 50%; transform: translateY(-50%)`), `z-index: 100`–`120`.
- Translucent surface: `rgba(245, 240, 232, 0.92)` with `backdrop-filter: blur(12px)`, `1px solid var(--line)`, `border-radius: 6px`, `padding: 5px`, `gap: 6px`.
- Square `34×34px` icon/label buttons (`.dock-btn`) with `border-radius: 4px`:
  - **Default:** transparent background, `--ink-2` stroke/text.
  - **Hover:** `--surface-hover`, `1px solid var(--line)`.
  - **Active (`aria-pressed="true"`):** `#0A2351` fill, `#FAF7F3` foreground.
- Contains **only actions directly relevant to the active view** (e.g. `Code`, `Snapshot`, `Fit`, `Wireframe`, `Params` in Studio; `3D`, `2D`, `Fit`, `Wire`, `Params`, `Info`, `Source` in `feascript-demo.html`).

### 4.3 Floating `lil-gui` Parameter Inspector (`.lil-gui.root`)
- Anchored `top: 14px; right: 14px` (`top: 8px; right: 8px` on mobile, collapsed by default on `< 768px`).
- Width: `280px`–`284px` desktop, `200px`–`224px` mobile, `max-height: calc(100dvh - 135px)`.
- Overrides `lil-gui` dark defaults using `!important` CSS variables (`--background-color: #F5F0E8`, `--title-background-color: #EDE6DB`, `--widget-color: #FAF7F3`, `--number-color: #0A2351`, slider fill `#0A2351`).
- Action buttons keep `#FAF7F3` background + `#0A2351` text at rest/focus and invert to `#0A2351` background + `#FAF7F3` text on `:hover`/`:active`.

### 4.4 Minimalist Unified Telemetry HUD (`.viewport-telemetry`)
- Anchored `bottom: 14px; right: 14px` (`8px` on mobile), `pointer-events: none`, right-aligned column (`gap: 2px`).
- Displays:
  1. Brand header (`.telemetry-brand`)
  2. Status indicator (`6×6px` `.status-dot` + loop/solver state)
  3. Primary physical metrics (dimensions, volume, thermal probe values)
  4. Mesh/frame stats (`FPS`, `Nodes`, `Triangles`, `Vertices`)

### 4.5 Native Info Modal & Mobile Bottom Sheet (`dialog#info-dialog`)
- Uses native `<dialog closedby="any">` with `rgba(5, 15, 31, 0.42)` blurred backdrop.
- **Desktop:** Centered card (`width: min(680px, calc(100vw - 28px))`, `border-radius: 6px`).
- **Mobile (`< 768px`):** Bottom sheet (`margin: auto 0 0 0; width: 100vw; max-height: 82dvh; border-radius: 12px 12px 0 0`).

### 4.6 Thermal Field Colormap (FEAScript × OpenCAD)
5-stop perceptual ramp for 2D FEM contours and 3D B-Rep vertex shading:

```
0.00  #1D3557  rgb( 29,  53,  87)   Coolant / Min
0.25  #2A9D8F  rgb( 42, 157, 143)
0.50  #E9C46A  rgb(233, 196, 106)
0.75  #F4A261  rgb(244, 162,  97)
1.00  #C1121F  rgb(193,  18,  31)   Heat Source / Max
```

### 4.7 Embed Mode (`?embed=true`)
- Hides non-essential studio chrome (`#viewport-stats`, optional `#code-pane` / `#btn-toggle-gui` via `?code=false` and `?params=false`) while keeping the central viewport `100vw × 100dvh`.

---

## 5. Brand Assets Inventory (`assets/brand/` & `web-app/public/branding/`)

| Asset | Purpose |
| :--- | :--- |
| `opencad-mark-navy.svg` / `opencad-mark-cream.svg` / `opencad-mark-light.svg` / `opencad-mark-dark.svg` | Isometric cube brand mark variants |
| `opencad-lockup-light.svg` / `opencad-lockup-dark.svg` | Horizontal mark + wordmark lockups |
| `opencad-icon-512.png` | 512×512 app icon |
| `opencad-social-og-light.{svg,png}` / `opencad-social-og-dark.{svg,png}` | Open Graph / social preview cards (`1200×630`) |
| `opencad-github-cover-light.{svg,png}` / `opencad-github-cover-dark.{svg,png}` | GitHub repository cover banners |
| `opencad-press-square-light.png` / `opencad-press-square-dark.png` | Square press & release cards |
| `web-app/public/branding/opencad-mark.svg`, `opencad-og.png` | Runtime favicon & OG tags (never rendered inside the 3D viewport) |
