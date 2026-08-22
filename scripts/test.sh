#!/usr/bin/env bash
# Run unit tests in headless Chrome.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
export CI=true NG_CLI_ANALYTICS=false

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

command -v npx >/dev/null 2>&1 || die "Missing command: npx"
[[ -d node_modules ]] || npm ci --no-audit --no-fund

if [[ -n "${CODEBUILD_BUILD_ID:-}" ]]; then
  if ! command -v google-chrome-stable >/dev/null 2>&1 \
    && ! command -v google-chrome >/dev/null 2>&1 \
    && ! command -v chromium-browser >/dev/null 2>&1 \
    && ! command -v chromium >/dev/null 2>&1; then
    log "Installing Chrome"
    export DEBIAN_FRONTEND=noninteractive
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y --no-install-recommends wget gnupg ca-certificates
      wget -qO- https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor > /usr/share/keyrings/google-linux.gpg
      echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-linux.gpg] http://dl.google.com/linux/chrome/deb/ stable main" \
        > /etc/apt/sources.list.d/google-chrome.list
      apt-get update -y
      apt-get install -y --no-install-recommends google-chrome-stable \
        || apt-get install -y --no-install-recommends chromium-browser || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y chromium
    fi
  fi
fi

export CHROME_BIN="${CHROME_BIN:-$(command -v google-chrome-stable || command -v google-chrome || command -v chromium-browser || command -v chromium || true)}"

log "Test"
npx ng test --watch=false --browsers="${KARMA_BROWSERS:-ChromeHeadlessCI}" --no-progress
log "Test complete"
