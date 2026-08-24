#!/usr/bin/env bash
# Production build and zip a revision for the pipeline artifact bucket.
#
# Required: SSM_BASE_PATH (no trailing slash), PIPELINE_EXEC_ID
# SSM parameters:
#   ${SSM_BASE_PATH}/shared/artifacts/bucket
# The API host is not baked in here; deploy.sh replaces http://localhost:3000
# with https://${DOMAIN_NAME} for the target environment.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"
export CI=true NG_CLI_ANALYTICS=false

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

need_env() { [[ -n "${!1:-}" ]] || die "Required environment variable is not set: $1"; }

ssm_get() {
  local name="$1"
  local value
  value="$(aws ssm get-parameter --name "${name}" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)" \
    || die "Failed to read SSM parameter ${name}"
  [[ -n "${value}" && "${value}" != "None" ]] || die "SSM parameter ${name} is empty"
  printf '%s\n' "${value}"
}

need_env SSM_BASE_PATH
need_env PIPELINE_EXEC_ID
[[ "${PIPELINE_EXEC_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid PIPELINE_EXEC_ID: ${PIPELINE_EXEC_ID}"

command -v aws >/dev/null 2>&1 || die "Missing command: aws"
command -v npx >/dev/null 2>&1 || die "Missing command: npx"
command -v node >/dev/null 2>&1 || die "Missing command: node"
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

SSM_BASE_PATH="${SSM_BASE_PATH%/}"
ARTIFACT_BUCKET="$(ssm_get "${SSM_BASE_PATH}/shared/artifacts/bucket")"

log "Build"
npx ng build --configuration production

DIST="${DIST_DIR:-dist/realworld-app/browser}"
[[ -f "${DIST}/index.html" ]] || die "Build output not found at ${DIST}"

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

DEST="s3://${ARTIFACT_BUCKET}/realworld-frontend/revisions/${ARTIFACT_VERSION}"
DEST_EXECUTION="s3://${ARTIFACT_BUCKET}/realworld-frontend/executions/${PIPELINE_EXEC_ID}"
log "Uploading ${DEST}"
aws s3 cp artifacts/frontend.zip "${DEST}/frontend.zip"
aws s3 cp artifacts/revision.txt "${DEST_EXECUTION}/revision.txt"

export ARTIFACT_VERSION
log "Build complete (artifact version ${ARTIFACT_VERSION})"
