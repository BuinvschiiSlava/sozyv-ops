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
: "${SOZYV_APP_CONTAINER:=sozyv-app}"
: "${SOZYV_POSTGRES_CONTAINER:=sozyv-postgres}"
: "${SOZYV_TURN_CONTAINER:=sozyv-turn}"
: "${SOZYV_FILES_VOLUME_NAME:=sozyv-files}"
: "${POSTGRES_ADMIN_USER:=postgres}"
: "${POSTGRES_DB:=sozyv}"
: "${BACKUP_DIR:=${ROOT_DIR}/runtime/backups}"
: "${METRICS_DIR:=${ROOT_DIR}/runtime/metrics}"
: "${BACKUP_MAX_AGE_HOURS:=26}"
: "${DISK_WARNING_PERCENT:=80}"
: "${DISK_CRITICAL_PERCENT:=90}"
: "${MEMORY_WARNING_PERCENT:=85}"
: "${TLS_WARNING_DAYS:=14}"

failures=0
warnings=0
checks=0

pass() { checks=$((checks + 1)); printf '[PASS] %s\n' "$*"; }
warn() { checks=$((checks + 1)); warnings=$((warnings + 1)); printf '[WARN] %s\n' "$*"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); printf '[FAIL] %s\n' "$*"; }

check_container() {
  local name=$1
  local required=$2
  local state health
  if ! state=$(docker inspect --format '{{.State.Status}}' "${name}" 2>/dev/null); then
    if [[ "${required}" == required ]]; then fail "container ${name} does not exist"; else warn "optional container ${name} does not exist"; fi
    return
  fi
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}not-configured{{end}}' "${name}")
  if [[ "${state}" != running ]]; then
    fail "container ${name} state=${state}"
  elif [[ "${health}" == unhealthy ]]; then
    fail "container ${name} health=unhealthy"
  elif [[ "${health}" == starting ]]; then
    warn "container ${name} health=starting"
  else
    pass "container ${name} running health=${health}"
  fi
}

printf 'Sozyv Ops diagnostic report — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' '------------------------------------------------------------'

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  pass 'Docker daemon is reachable'
  check_container "${SOZYV_APP_CONTAINER}" required
  check_container "${SOZYV_POSTGRES_CONTAINER}" required
  [[ -z "${SOZYV_TURN_CONTAINER}" ]] || check_container "${SOZYV_TURN_CONTAINER}" optional

  if docker volume inspect "${SOZYV_FILES_VOLUME_NAME}" >/dev/null 2>&1; then
    pass "attachment volume ${SOZYV_FILES_VOLUME_NAME} exists"
  else
    fail "attachment volume ${SOZYV_FILES_VOLUME_NAME} is missing"
  fi

  if docker exec "${SOZYV_POSTGRES_CONTAINER}" pg_isready -U "${POSTGRES_ADMIN_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
    pass 'PostgreSQL accepts connections'
  else
    fail 'PostgreSQL readiness check failed'
  fi
else
  fail 'Docker daemon is unavailable'
fi

if command -v curl >/dev/null 2>&1 && curl --fail --silent --show-error --max-time 8 "${SOZYV_HEALTH_URL}" >/dev/null; then
  pass "health endpoint ${SOZYV_HEALTH_URL}"
else
  fail "health endpoint failed: ${SOZYV_HEALTH_URL}"
fi

disk_used=$(df -P / | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')
if (( disk_used >= DISK_CRITICAL_PERCENT )); then
  fail "root filesystem usage is ${disk_used}%"
elif (( disk_used >= DISK_WARNING_PERCENT )); then
  warn "root filesystem usage is ${disk_used}%"
else
  pass "root filesystem usage is ${disk_used}%"
fi

if [[ -r /proc/meminfo ]]; then
  mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  mem_available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  memory_used=$((100 - mem_available * 100 / mem_total))
  if (( memory_used >= MEMORY_WARNING_PERCENT )); then warn "memory usage is ${memory_used}%"; else pass "memory usage is ${memory_used}%"; fi
else
  warn 'Linux memory information is unavailable'
fi

latest_file="${BACKUP_DIR}/latest.txt"
if [[ -f "${latest_file}" ]]; then
  latest_id=$(tr -d '\r\n' < "${latest_file}")
  latest_path="${BACKUP_DIR}/${latest_id}"
  if [[ -d "${latest_path}" && -f "${latest_path}/SHA256SUMS" ]]; then
    latest_epoch=$(stat -c %Y "${latest_path}/SHA256SUMS")
    age_hours=$((( $(date +%s) - latest_epoch ) / 3600))
    if (( age_hours > BACKUP_MAX_AGE_HOURS )); then fail "latest backup is ${age_hours}h old"; else pass "latest backup is ${age_hours}h old"; fi
  else
    fail 'latest.txt points to an incomplete backup'
  fi
else
  fail 'no backup metadata was found'
fi

if [[ "${SOZYV_HEALTH_URL}" == https://* ]] && command -v openssl >/dev/null 2>&1; then
  tls_host=${SOZYV_HEALTH_URL#https://}
  tls_host=${tls_host%%/*}
  tls_host=${tls_host%%:*}
  end_date=$(timeout 10 openssl s_client -servername "${tls_host}" -connect "${tls_host}:443" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2- || true)
  if [[ -n "${end_date}" ]]; then
    end_epoch=$(date -d "${end_date}" +%s)
    tls_days=$(((end_epoch - $(date +%s)) / 86400))
    if (( tls_days < 0 )); then fail 'TLS certificate is expired'; elif (( tls_days < TLS_WARNING_DAYS )); then warn "TLS certificate expires in ${tls_days} days"; else pass "TLS certificate expires in ${tls_days} days"; fi
  else
    fail 'TLS certificate could not be inspected'
  fi
fi

mkdir -p "${METRICS_DIR}"
metric_tmp="${METRICS_DIR}/.sozyv_doctor.prom.$$"
if (( failures == 0 )); then doctor_ok=1; else doctor_ok=0; fi
cat > "${metric_tmp}" <<EOF
# HELP sozyv_doctor_ok Whether the latest diagnostic run found zero failures.
# TYPE sozyv_doctor_ok gauge
sozyv_doctor_ok ${doctor_ok}
# HELP sozyv_doctor_failures Number of failed checks in the latest diagnostic run.
# TYPE sozyv_doctor_failures gauge
sozyv_doctor_failures ${failures}
# HELP sozyv_doctor_warnings Number of warning checks in the latest diagnostic run.
# TYPE sozyv_doctor_warnings gauge
sozyv_doctor_warnings ${warnings}
# HELP sozyv_doctor_last_run_timestamp_seconds Unix timestamp of the latest diagnostic run.
# TYPE sozyv_doctor_last_run_timestamp_seconds gauge
sozyv_doctor_last_run_timestamp_seconds $(date +%s)
EOF
chmod 0644 "${metric_tmp}"
mv "${metric_tmp}" "${METRICS_DIR}/sozyv_doctor.prom"

printf '%s\n' '------------------------------------------------------------'
printf 'Checks: %s; warnings: %s; failures: %s\n' "${checks}" "${warnings}" "${failures}"
(( failures == 0 ))
