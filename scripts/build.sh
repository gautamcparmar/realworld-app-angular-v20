#!/usr/bin/env bash
# Production build and zip a revision for the pipeline artifact bucket.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
export CI=true NG_CLI_ANALYTICS=false

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

command -v npx >/dev/null 2>&1 || die "Missing command: npx"
[[ -d node_modules ]] || npm ci --no-audit --no-fund

if ! command -v zip >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends zip
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y zip
  else
    die "Missing command: zip"
  fi
fi

log "Build"
npx ng build --configuration production

DIST="${DIST_DIR:-dist/realworld-app/browser}"
[[ -f "${DIST}/index.html" ]] || die "Build output not found at ${DIST}"

command -v node >/dev/null 2>&1 || die "Missing command: node"
PKG_VERSION="$(node -p "require('./package.json').version")"
[[ -n "${PKG_VERSION}" && "${PKG_VERSION}" != "undefined" ]] || die "package.json version is missing"

if [[ -n "${CODEBUILD_BUILD_ID:-}" && -z "${CODEBUILD_BUILD_NUMBER:-}" ]]; then
  die "CODEBUILD_BUILD_NUMBER is required"
fi

ARTIFACT_VERSION="${PKG_VERSION}.${CODEBUILD_BUILD_NUMBER:-0}"
[[ "${ARTIFACT_VERSION}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid ARTIFACT_VERSION: ${ARTIFACT_VERSION}"

mkdir -p artifacts
rm -f artifacts/frontend.zip
( cd "${DIST}" && zip -r -q "${ROOT}/artifacts/frontend.zip" . )
printf '%s\n' "${ARTIFACT_VERSION}" > artifacts/revision.txt

if [[ -n "${ARTIFACT_BUCKET:-}" ]]; then
  command -v aws >/dev/null 2>&1 || die "Missing command: aws"
  DEST="s3://${ARTIFACT_BUCKET}/revisions/${ARTIFACT_VERSION}"
  log "Uploading ${DEST}"
  aws s3 cp artifacts/frontend.zip "${DEST}/frontend.zip"
  aws s3 cp artifacts/revision.txt "${DEST}/revision.txt"
fi

export ARTIFACT_VERSION
log "Build complete (artifact version ${ARTIFACT_VERSION})"
