---
name: verify-web-viewport
description: Runs the Playwright automated test suite in web-app/ to verify WebGL context initialization, steady 60-FPS rendering throughput, and sub-shape face and edge raycast picking.
---

# Skill: verify-web-viewport

## Overview
This skill executes the end-to-end browser test automation suite for `open-parametric-cad`. It validates that the Three.js viewport initializes properly, loads and unpacks zero-copy flat memory slices from the Web Worker, maintains steady 60 FPS rendering throughput, and accurately performs sub-shape topological face and edge selection.

## When to Use
- Whenever modifying files in `web-app/` (`src/renderer/`, `src/worker/`, `src/ui/`, or `index.html`).
- After updating Web Worker messaging or Transferable ArrayBuffer layouts.
- Prior to finalizing any frontend or UI milestone.

## Procedure
Execute the verification script from the project root:

```bash
bash .agents/skills/verify-web-viewport/scripts/verify.sh
```

Alternatively, run the browser test suites manually:
```bash
# Playwright test suite
npm --prefix web-app run test

# Puppeteer test suite
npm --prefix web-app run test:puppeteer
```

## Acceptance Criteria
- WebGL rendering context initializes with valid vertex/face stats.
- Rendering benchmark validates steady 60+ FPS frame rates (< 16.7 ms frame interval).
- Raycast pointer interaction accurately identifies topological Face IDs (`Face #1`, `Face #2`, etc.) via `triangle_to_face_id`.
- Feature edge picking accurately identifies Edge IDs.
- Dynamic geometry regeneration smoothly updates the viewport without memory leaks.
