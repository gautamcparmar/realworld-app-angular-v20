#!/usr/bin/env bash
# Lint / typecheck the application.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
export CI=true NG_CLI_ANALYTICS=false

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

command -v npx >/dev/null 2>&1 || die "Missing command: npx"
[[ -d node_modules ]] || npm ci --no-audit --no-fund

log "Validate"
npx tsc -p tsconfig.app.json --noEmit
log "Validate complete"
