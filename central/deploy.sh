#!/usr/bin/env bash
# One-click deployment of the central visualization stack.
#
# Brings up:
#   - Prometheus on :${PROMETHEUS_PORT:-9090} with --web.enable-remote-write-receiver
#   - Grafana    on :${GRAFANA_PORT:-3000}     with the Prometheus datasource auto-provisioned
#
# Idempotent: re-running just recreates containers as needed.
set -euo pipefail

PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"

cd "$(dirname "$0")"

say()   { printf '\033[1;36m[central]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[central]\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m[central]\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Docker / Compose preflight.
command -v docker >/dev/null 2>&1 \
  || fail "docker not found — install Docker first: https://docs.docker.com/engine/install/"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  fail "Docker Compose not found — install the v2 plugin: https://docs.docker.com/compose/install/"
fi

# 2. Bring containers up.
say "starting prometheus and grafana ..."
PROMETHEUS_PORT="${PROMETHEUS_PORT}" \
GRAFANA_PORT="${GRAFANA_PORT}" \
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER}" \
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD}" \
  "${COMPOSE[@]}" up -d

# 3. Wait for Prometheus.
say "waiting for prometheus /-/ready on :${PROMETHEUS_PORT} ..."
prom_ok=0
for i in {1..30}; do
  if curl -fsS --max-time 2 "http://127.0.0.1:${PROMETHEUS_PORT}/-/ready" -o /dev/null; then
    prom_ok=1; break
  fi
  sleep 1
done
[ "${prom_ok}" = 1 ] || warn "prometheus did not become ready in 30s — check 'docker compose logs prometheus'."

# 4. Confirm remote-write receiver is on.
flags_json="$(curl -fsS --max-time 5 "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/status/flags" 2>/dev/null || true)"
if echo "${flags_json}" | grep -q '"web.enable-remote-write-receiver":"true"'; then
  say "remote-write receiver is enabled — POST samples to /api/v1/write."
else
  warn "remote-write receiver flag NOT reported — check the prometheus container's command line."
fi

# 5. Wait for Grafana.
say "waiting for grafana /api/health on :${GRAFANA_PORT} ..."
graf_ok=0
for i in {1..60}; do
  health="$(curl -fsS --max-time 2 "http://127.0.0.1:${GRAFANA_PORT}/api/health" 2>/dev/null || true)"
  if echo "${health}" | grep -q '"database": "ok"'; then
    graf_ok=1; break
  fi
  sleep 1
done
[ "${graf_ok}" = 1 ] || warn "grafana did not become healthy in 60s — check 'docker compose logs grafana'."

cat <<EOF

================================================================
  Central visualization stack is up.

  Prometheus: http://127.0.0.1:${PROMETHEUS_PORT}
              remote_write endpoint: http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/write
  Grafana:    http://127.0.0.1:${GRAFANA_PORT}   (login: ${GRAFANA_ADMIN_USER} / ${GRAFANA_ADMIN_PASSWORD})

  On each GPU node, point the agent at this host:
    cd gpu_monitor/gpu_node
    ./deploy.sh \\
      --PROMETHEUS_URL http://<this-host>:${PROMETHEUS_PORT} \\
      --GRAFANA_URL    http://<this-host>:${GRAFANA_PORT}
================================================================
EOF
