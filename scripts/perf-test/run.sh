#!/usr/bin/env bash
# k6 performance regression against staging CloudFront. A failing run blocks
# the pipeline before the production approval stage.
#
# Required in CI: ENVIRONMENT=stage, SSM_BASE_PATH (no trailing slash)
# Optional: BASE_URL (skips SSM api/url), PERF_VUS, PERF_P95_MS, PERF_P99_MS,
#           PERF_REGRESSION_PERCENT (default 20), PIPELINE_EXEC_ID
#
# SSM parameters:
#   ${SSM_BASE_PATH}/shared/artifacts/bucket
#   ${SSM_BASE_PATH}/${ENVIRONMENT}/api/url
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

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

install_k6() {
  if command -v k6 >/dev/null 2>&1; then
    return
  fi
  need_cmd curl
  need_cmd tar
  local version="${K6_VERSION:-v0.57.0}"
  local arch
  case "$(uname -m)" in
    x86_64 | amd64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
  local tmp
  tmp="$(mktemp -d)"
  local url="https://github.com/grafana/k6/releases/download/${version}/k6-${version}-linux-${arch}.tar.gz"
  log "Installing k6 ${version} (${arch})"
  curl -fsSL "${url}" -o "${tmp}/k6.tgz"
  tar -xzf "${tmp}/k6.tgz" -C "${tmp}"
  mkdir -p "${ROOT}/.k6"
  cp "${tmp}/k6-${version}-linux-${arch}/k6" "${ROOT}/.k6/k6"
  chmod +x "${ROOT}/.k6/k6"
  export PATH="${ROOT}/.k6:${PATH}"
  rm -rf "${tmp}"
}

ENVIRONMENT="${ENVIRONMENT:-stage}"
[[ "${ENVIRONMENT}" == "stage" ]] || die "performance-test only runs against stage"
if [[ -n "${SSM_BASE_PATH:-}" ]]; then
  SSM_BASE_PATH="${SSM_BASE_PATH%/}"
fi

need_cmd python3
install_k6
need_cmd k6

if [[ -z "${BASE_URL:-}" ]]; then
  need_cmd aws
  need_env SSM_BASE_PATH
  BASE_URL="$(ssm_get "${SSM_BASE_PATH}/${ENVIRONMENT}/api/url")"
fi
BASE_URL="${BASE_URL%/}"
[[ "${BASE_URL}" == http://* || "${BASE_URL}" == https://* ]] || BASE_URL="https://${BASE_URL}"
export BASE_URL
log "Running k6 against ${BASE_URL}"

mkdir -p artifacts/perf
SUMMARY="${ROOT}/artifacts/perf/summary.json"
rm -f "${SUMMARY}"

set +e
k6 run \
  --summary-export "${SUMMARY}" \
  "${ROOT}/scripts/perf-test/load.js"
K6_STATUS=$?
set -e
[[ -f "${SUMMARY}" ]] || die "k6 did not write ${SUMMARY}"
if [[ "${K6_STATUS}" -ne 0 ]]; then
  log "k6 thresholds failed (exit ${K6_STATUS})"
fi

ARTIFACT_BUCKET="${ARTIFACT_BUCKET:-}"
if [[ -z "${ARTIFACT_BUCKET}" && -n "${SSM_BASE_PATH:-}" ]]; then
  need_cmd aws
  ARTIFACT_BUCKET="$(ssm_get "${SSM_BASE_PATH}/shared/artifacts/bucket")"
fi

COMPARE_STATUS=2
if [[ -n "${ARTIFACT_BUCKET}" ]]; then
  need_cmd aws
  RUN_ID="${PIPELINE_EXEC_ID:-local}"
  [[ "${RUN_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid PIPELINE_EXEC_ID: ${RUN_ID}"
  PREFIX="s3://${ARTIFACT_BUCKET}/realworld-frontend/perf/${ENVIRONMENT}"
  BASELINE_KEY="${PREFIX}/baseline.json"
  RUN_KEY="${PREFIX}/runs/${RUN_ID}/summary.json"
  BASELINE_FILE="${ROOT}/artifacts/perf/baseline.json"
  rm -f "${BASELINE_FILE}"
  log "Uploading ${RUN_KEY}"
  aws s3 cp "${SUMMARY}" "${RUN_KEY}"
  if aws s3 cp "${BASELINE_KEY}" "${BASELINE_FILE}" 2>/dev/null; then
    log "Comparing against ${BASELINE_KEY}"
  else
    log "No baseline at ${BASELINE_KEY}"
  fi
  set +e
  python3 "${ROOT}/scripts/perf-test/compare.py" \
    --current "${SUMMARY}" \
    --baseline "${BASELINE_FILE}" \
    --percent "${PERF_REGRESSION_PERCENT:-20}"
  COMPARE_STATUS=$?
  set -e
  if [[ "${K6_STATUS}" -eq 0 && ( "${COMPARE_STATUS}" -eq 0 || "${COMPARE_STATUS}" -eq 2 ) ]]; then
    log "Updating baseline ${BASELINE_KEY}"
    aws s3 cp "${SUMMARY}" "${BASELINE_KEY}"
  fi
else
  log "ARTIFACT_BUCKET / SSM_BASE_PATH not set; skipping baseline comparison"
  python3 "${ROOT}/scripts/perf-test/compare.py" \
    --current "${SUMMARY}" \
    --baseline "${ROOT}/artifacts/perf/baseline.json" \
    --percent "${PERF_REGRESSION_PERCENT:-20}" \
    || true
fi

if [[ "${K6_STATUS}" -ne 0 ]]; then
  die "Performance test failed k6 thresholds; not promoting to production approval"
fi
if [[ "${COMPARE_STATUS}" -eq 1 ]]; then
  die "Performance regression vs staging baseline; not promoting to production approval"
fi
log "Performance test passed"
