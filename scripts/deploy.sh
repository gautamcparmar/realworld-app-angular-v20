#!/usr/bin/env bash
# Deploy a zipped artifact: S3 version prefix + CloudFront origin path + invalidation.
#
# Required: ENVIRONMENT (stage|production), SSM_BASE_PATH (no trailing slash)
# Optional: ARTIFACT_VERSION, ARTIFACT_PATH, CLOUDFRONT_ORIGIN_ID,
#           WAIT_FOR_DISTRIBUTION (default true), WAIT_FOR_INVALIDATION (true on production)
#
# SSM parameters:
#   ${SSM_BASE_PATH}/${ENVIRONMENT}/frontend/bucket
#   ${SSM_BASE_PATH}/${ENVIRONMENT}/cloudfront/distribution-id
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }
need_env() { [[ -n "${!1:-}" ]] || die "Required environment variable is not set: $1"; }

ssm_get() {
  local name="$1"
  local value
  value="$(aws ssm get-parameter --name "${name}" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)" \
    || die "Failed to read SSM parameter ${name}"
  [[ -n "${value}" && "${value}" != "None" ]] || die "SSM parameter ${name} is empty"
  printf '%s\n' "${value}"
}

need_cmd aws
need_cmd jq
need_cmd unzip
need_env ENVIRONMENT
need_env SSM_BASE_PATH

[[ "${ENVIRONMENT}" == "stage" || "${ENVIRONMENT}" == "production" ]] \
  || die "ENVIRONMENT must be 'stage' or 'production'"

SSM_BASE_PATH="${SSM_BASE_PATH%/}"
HOSTING_BUCKET="$(ssm_get "${SSM_BASE_PATH}/${ENVIRONMENT}/frontend/bucket")"
CLOUDFRONT_DISTRIBUTION_ID="$(ssm_get "${SSM_BASE_PATH}/${ENVIRONMENT}/cloudfront/distribution-id")"
log "Loaded HOSTING_BUCKET=${HOSTING_BUCKET} and CLOUDFRONT_DISTRIBUTION_ID=${CLOUDFRONT_DISTRIBUTION_ID} from SSM"

if [[ "${ENVIRONMENT}" == "production" ]]; then
  WAIT_FOR_INVALIDATION="${WAIT_FOR_INVALIDATION:-true}"
fi

ZIP="${ARTIFACT_PATH:-${ROOT}/artifacts/frontend.zip}"
[[ -f "${ZIP}" ]] || ZIP="${ROOT}/frontend.zip"
[[ -f "${ZIP}" ]] || die "frontend.zip not found. Set ARTIFACT_PATH."

if [[ -z "${ARTIFACT_VERSION:-}" && -f "${ROOT}/artifacts/revision.txt" ]]; then
  ARTIFACT_VERSION="$(tr -d '[:space:]' < "${ROOT}/artifacts/revision.txt")"
fi
if [[ -z "${ARTIFACT_VERSION:-}" && -f "$(dirname "${ZIP}")/revision.txt" ]]; then
  ARTIFACT_VERSION="$(tr -d '[:space:]' < "$(dirname "${ZIP}")/revision.txt")"
fi
[[ -n "${ARTIFACT_VERSION:-}" ]] || die "ARTIFACT_VERSION is required (or provide artifacts/revision.txt)"
[[ "${ARTIFACT_VERSION}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid ARTIFACT_VERSION: ${ARTIFACT_VERSION}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SITE="${WORK}/site"
mkdir -p "${SITE}"

log "Deploying artifact version ${ARTIFACT_VERSION} to ${ENVIRONMENT}"
unzip -q -o "${ZIP}" -d "${SITE}"
[[ -f "${SITE}/index.html" ]] || die "Artifact does not contain index.html"

DEST="s3://${HOSTING_BUCKET}/${ARTIFACT_VERSION}"
log "Syncing ${DEST}/"
aws s3 sync "${SITE}" "${DEST}" \
  --exclude "*" --include "*.html" --include "*.json" \
  --cache-control "no-cache, no-store, must-revalidate" \
  --only-show-errors
aws s3 sync "${SITE}" "${DEST}" \
  --exclude "*.html" --exclude "*.json" \
  --cache-control "public, max-age=31536000, immutable" \
  --only-show-errors

ORIGIN_PATH="/${ARTIFACT_VERSION}"
CFG="${WORK}/cf.json"

update_cloudfront() {
  local payload etag
  payload="$(aws cloudfront get-distribution-config --id "${CLOUDFRONT_DISTRIBUTION_ID}" --output json)" || return 1
  etag="$(jq -r '.ETag' <<<"${payload}")"
  jq --arg path "${ORIGIN_PATH}" --arg origin "${CLOUDFRONT_ORIGIN_ID:-}" '
    .DistributionConfig
    | .Origins.Items |= map(if $origin == "" or .Id == $origin then .OriginPath = $path else . end)
    | .DefaultRootObject = (if .DefaultRootObject == null or .DefaultRootObject == "" then "index.html" else .DefaultRootObject end)
  ' <<<"${payload}" > "${CFG}"
  aws cloudfront update-distribution \
    --id "${CLOUDFRONT_DISTRIBUTION_ID}" \
    --if-match "${etag}" \
    --distribution-config "file://${CFG}" \
    --output json >/dev/null || return 1
}

log "Updating CloudFront ${CLOUDFRONT_DISTRIBUTION_ID} origin path to ${ORIGIN_PATH}"
ok=0
for attempt in 1 2 3 4 5; do
  if update_cloudfront; then
    ok=1
    break
  fi
  log "CloudFront update attempt ${attempt} failed; retrying"
  sleep $((attempt * 2))
done
[[ "${ok}" -eq 1 ]] || die "Failed to update CloudFront distribution"

INVALIDATION_ID="$(
  aws cloudfront create-invalidation \
    --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
    --paths "${CLOUDFRONT_INVALIDATION_PATHS:-/*}" \
    --query 'Invalidation.Id' \
    --output text
)"
log "Created CloudFront invalidation ${INVALIDATION_ID}"

if [[ "${WAIT_FOR_DISTRIBUTION:-true}" == "true" ]]; then
  log "Waiting for CloudFront deployment"
  aws cloudfront wait distribution-deployed --id "${CLOUDFRONT_DISTRIBUTION_ID}"
fi

if [[ "${WAIT_FOR_INVALIDATION:-false}" == "true" ]]; then
  log "Waiting for CloudFront invalidation ${INVALIDATION_ID}"
  aws cloudfront wait invalidation-completed \
    --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
    --id "${INVALIDATION_ID}"
fi

log "Deploy to ${ENVIRONMENT} complete (artifact version ${ARTIFACT_VERSION})"
