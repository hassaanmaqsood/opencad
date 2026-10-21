#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WEB_APP_DIR="${REPO_ROOT}/web-app"

echo "=== [Skill: verify-web-viewport] Step 1: Building TypeScript Codebase ==="
(cd "${WEB_APP_DIR}" && npm run build)

echo "=== [Skill: verify-web-viewport] Step 2: Running Playwright 60 FPS & Picking Suite ==="
(cd "${WEB_APP_DIR}" && npx playwright test)

echo "=== [Skill: verify-web-viewport] SUCCESS: Web viewport 60 FPS & picking verified! ==="
