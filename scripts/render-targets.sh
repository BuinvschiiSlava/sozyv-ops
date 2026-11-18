#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  printf 'Missing .env. Copy .env.example to .env first.\n' >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "${ROOT_DIR}/.env"
set +a

: "${SOZYV_HEALTH_URL:?Set SOZYV_HEALTH_URL in .env}"
if [[ ! "${SOZYV_HEALTH_URL}" =~ ^https?://[^[:space:]\"]+$ ]]; then
  printf 'SOZYV_HEALTH_URL must be an HTTP or HTTPS URL without spaces or quotes.\n' >&2
  exit 1
fi

target_dir="${ROOT_DIR}/monitoring/prometheus/generated"
mkdir -p "${target_dir}"
tmp="${target_dir}/.blackbox.json.$$"
printf '[{"targets":["%s"],"labels":{"service":"sozyv"}}]\n' "${SOZYV_HEALTH_URL}" > "${tmp}"
mv "${tmp}" "${target_dir}/blackbox.json"

printf 'Prometheus target rendered: %s\n' "${SOZYV_HEALTH_URL}"
