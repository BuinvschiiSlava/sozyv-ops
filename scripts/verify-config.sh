#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

command -v docker >/dev/null 2>&1 || { printf 'Missing command: docker\n' >&2; exit 1; }

[[ -f .env ]] || { printf 'Copy .env.example to .env first.\n' >&2; exit 1; }
./scripts/render-targets.sh
docker compose --env-file .env config --quiet

repo_path=$(pwd)
case "${MSYSTEM:-}" in
  MINGW*|MSYS*)
    repo_path=$(pwd -W)
    export MSYS_NO_PATHCONV=1
    ;;
esac
if command -v jq >/dev/null 2>&1; then
  jq empty monitoring/grafana/dashboards/sozyv-ops.json monitoring/prometheus/generated/blackbox.json
else
  docker run --rm -v "${repo_path}:/work:ro" ghcr.io/jqlang/jq:1.8.1 \
    empty /work/monitoring/grafana/dashboards/sozyv-ops.json /work/monitoring/prometheus/generated/blackbox.json
fi

docker run --rm -v "${repo_path}/monitoring/prometheus:/etc/prometheus:ro" \
  --entrypoint /bin/promtool prom/prometheus:v3.13.5 \
  check config /etc/prometheus/prometheus.yml
docker run --rm -v "${repo_path}/monitoring/alertmanager:/etc/alertmanager:ro" --entrypoint amtool prom/alertmanager:v0.35.0 \
  check-config /etc/alertmanager/alertmanager.yml

printf 'Configuration validation passed.\n'
