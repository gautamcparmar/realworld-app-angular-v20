#!/usr/bin/env bash
# Deploy a zipped artifact: S3 version prefix + CloudFront origin path + invalidation.
#
# Required: ENVIRONMENT (stage|production), SSM_BASE_PATH (no trailing slash),
#           PIPELINE_EXEC_ID
# Optional: ARTIFACT_PATH, CLOUDFRONT_ORIGIN_ID,
#           WAIT_FOR_DISTRIBUTION (default true), WAIT_FOR_INVALIDATION (true on production)
#
# SSM parameters:
#   ${SSM_BASE_PATH}/shared/artifacts/bucket
#   ${SSM_BASE_PATH}/${ENVIRONMENT}/frontend/bucket
#   ${SSM_BASE_PATH}/${ENVIRONMENT}/cloudfront/distribution-id
#   ${SSM_BASE_PATH}/${ENVIRONMENT}/domain_name
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
need_env PIPELINE_EXEC_ID

[[ "${ENVIRONMENT}" == "stage" || "${ENVIRONMENT}" == "production" ]] \
  || die "ENVIRONMENT must be 'stage' or 'production'"

SSM_BASE_PATH="${SSM_BASE_PATH%/}"
ARTIFACT_BUCKET="$(ssm_get "${SSM_BASE_PATH}/shared/artifacts/bucket")"
HOSTING_BUCKET="$(ssm_get "${SSM_BASE_PATH}/${ENVIRONMENT}/frontend/bucket")"
CLOUDFRONT_DISTRIBUTION_ID="$(ssm_get "${SSM_BASE_PATH}/${ENVIRONMENT}/cloudfront/distribution-id")"
DOMAIN_NAME="$(ssm_get "${SSM_BASE_PATH}/${ENVIRONMENT}/domain_name")"
DOMAIN_NAME="${DOMAIN_NAME#http://}"
DOMAIN_NAME="${DOMAIN_NAME#https://}"
DOMAIN_NAME="${DOMAIN_NAME%/}"
[[ -n "${DOMAIN_NAME}" ]] || die "domain_name SSM parameter is empty"
API_ORIGIN="https://${DOMAIN_NAME}"
log "Loaded ARTIFACT_BUCKET=${ARTIFACT_BUCKET}, HOSTING_BUCKET=${HOSTING_BUCKET}, CLOUDFRONT_DISTRIBUTION_ID=${CLOUDFRONT_DISTRIBUTION_ID} from SSM"
log "Using API origin ${API_ORIGIN} for ${ENVIRONMENT}"

if [[ "${ENVIRONMENT}" == "production" ]]; then
  WAIT_FOR_INVALIDATION="${WAIT_FOR_INVALIDATION:-true}"
fi

[[ "${PIPELINE_EXEC_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid PIPELINE_EXEC_ID: ${PIPELINE_EXEC_ID}"
REVISION_KEY="s3://${ARTIFACT_BUCKET}/realworld-frontend/executions/${PIPELINE_EXEC_ID}/revision.txt"
ARTIFACT_VERSION="$(aws s3 cp "${REVISION_KEY}" - 2>/dev/null | tr -d '[:space:]')" \
  || die "Failed to read ARTIFACT_VERSION from ${REVISION_KEY}"
[[ -n "${ARTIFACT_VERSION}" ]] || die "${REVISION_KEY} is empty"
[[ "${ARTIFACT_VERSION}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid ARTIFACT_VERSION: ${ARTIFACT_VERSION}"
log "Using ARTIFACT_VERSION=${ARTIFACT_VERSION} from ${REVISION_KEY}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
SITE="${WORK}/site"
ZIP="${WORK}/frontend.zip"
mkdir -p "${SITE}"

if [[ -n "${ARTIFACT_PATH:-}" && -f "${ARTIFACT_PATH}" ]]; then
  cp "${ARTIFACT_PATH}" "${ZIP}"
else
  REMOTE_ZIP="s3://${ARTIFACT_BUCKET}/realworld-frontend/revisions/${ARTIFACT_VERSION}/frontend.zip"
  log "Downloading ${REMOTE_ZIP}"
  aws s3 cp "${REMOTE_ZIP}" "${ZIP}" || die "Failed to download ${REMOTE_ZIP}"
fi
[[ -f "${ZIP}" ]] || die "frontend.zip not found"

log "Deploying artifact version ${ARTIFACT_VERSION} to ${ENVIRONMENT}"
unzip -q -o "${ZIP}" -d "${SITE}"
[[ -f "${SITE}/index.html" ]] || die "Artifact does not contain index.html"

placeholder='http://localhost:3000'
updated=0
while IFS= read -r file; do
  [[ -f "${file}" ]] || continue
  content=$(cat "${file}"; printf x)
  content="${content%x}"
  [[ "${content}" == *"${placeholder}"* ]] || continue
  printf '%s' "${content//${placeholder}/${API_ORIGIN}}" > "${file}.tmp"
  mv "${file}.tmp" "${file}"
  updated=$((updated + 1))
done < <(find "${SITE}" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.html' -o -name '*.json' -o -name '*.css' -o -name '*.map' \))
[[ "${updated}" -gt 0 ]] || die "http://localhost:3000 not found in the artifact; rebuild so the API URL placeholder is present"
log "Rewrote API origin to ${API_ORIGIN} in ${updated} file(s)"

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
