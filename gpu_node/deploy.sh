#!/usr/bin/env bash
# One-click deployment of the GPU push agent on a GPU host behind NAT.
#
# Brings up:
#   - nvidia/dcgm-exporter on :9400 (compose-internal)
#   - prom/prometheus (agent mode) that scrapes dcgm-exporter and
#     remote_writes samples to the central Prometheus.
set -euo pipefail

EXPORTER_PORT="${EXPORTER_PORT:-9400}"
AGENT_PORT="${AGENT_PORT:-9091}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://143.198.139.25:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://143.198.139.25:3000}"
REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-}"
INSTANCE_LABEL="${INSTANCE_LABEL:-$(hostname)}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --PROMETHEUS_URL <url>   Central Prometheus base URL (default: ${PROMETHEUS_URL})
  --GRAFANA_URL    <url>   Central Grafana base URL    (default: ${GRAFANA_URL})
  --REMOTE_WRITE_URL <url> Override the push endpoint  (default: <PROMETHEUS_URL>/api/v1/write)
  --INSTANCE_LABEL <name>  Label attached to every series (default: \$(hostname))
  --EXPORTER_PORT  <port>  Host port for dcgm-exporter  (default: ${EXPORTER_PORT})
  --AGENT_PORT     <port>  Host port for the agent UI   (default: ${AGENT_PORT})
  -h, --help               Show this help

Environment variables of the same name are honoured as fallbacks; CLI flags win.
EOF
}

# Parse CLI flags. Both --FOO value and --FOO=value forms are accepted.
while [ $# -gt 0 ]; do
  case "$1" in
    --PROMETHEUS_URL)    PROMETHEUS_URL="$2"; shift 2 ;;
    --PROMETHEUS_URL=*)  PROMETHEUS_URL="${1#*=}"; shift ;;
    --GRAFANA_URL)       GRAFANA_URL="$2"; shift 2 ;;
    --GRAFANA_URL=*)     GRAFANA_URL="${1#*=}"; shift ;;
    --REMOTE_WRITE_URL)  REMOTE_WRITE_URL="$2"; shift 2 ;;
    --REMOTE_WRITE_URL=*) REMOTE_WRITE_URL="${1#*=}"; shift ;;
    --INSTANCE_LABEL)    INSTANCE_LABEL="$2"; shift 2 ;;
    --INSTANCE_LABEL=*)  INSTANCE_LABEL="${1#*=}"; shift ;;
    --EXPORTER_PORT)     EXPORTER_PORT="$2"; shift 2 ;;
    --EXPORTER_PORT=*)   EXPORTER_PORT="${1#*=}"; shift ;;
    --AGENT_PORT)        AGENT_PORT="$2"; shift 2 ;;
    --AGENT_PORT=*)      AGENT_PORT="${1#*=}"; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-${PROMETHEUS_URL}/api/v1/write}"

cd "$(dirname "$0")"

say()   { printf '\033[1;36m[deploy]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[deploy]\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m[deploy]\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Docker
command -v docker >/dev/null 2>&1 \
  || fail "docker not found — install Docker first: https://docs.docker.com/engine/install/"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  fail "Docker Compose not found — install the v2 plugin: https://docs.docker.com/compose/install/"
fi

# 2. NVIDIA driver
command -v nvidia-smi >/dev/null 2>&1 \
  || fail "nvidia-smi not found — install the NVIDIA driver before deploying the exporter."

# 3. NVIDIA Container Toolkit
if ! docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia'; then
  warn "NVIDIA Container Toolkit not detected in 'docker info'."
  warn "Install: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
  warn "Then: sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker"
  fail "Aborting — exporter cannot access GPUs without the toolkit."
fi

# 4. Render prometheus.yml from template (escape sed delimiters in URL).
#    Inside the container, 127.0.0.1/localhost would resolve to the
#    container itself, not the host running the central stack. Rewrite to
#    host.docker.internal (mapped via extra_hosts) only for the agent's
#    config — the host-side probes below still use the URL as supplied.
container_remote_write_url="${REMOTE_WRITE_URL}"
case "${container_remote_write_url}" in
  *://127.0.0.1:*|*://127.0.0.1/*|*://localhost:*|*://localhost/*)
    container_remote_write_url="$(echo "${REMOTE_WRITE_URL}" \
      | sed -E 's#://(127\.0\.0\.1|localhost)([:/])#://host.docker.internal\2#')"
    say "rewriting agent's remote_write target to ${container_remote_write_url} (so the container can reach the host)."
    ;;
esac

say "rendering prometheus.yml (instance=${INSTANCE_LABEL}, remote_write=${container_remote_write_url}) ..."
escaped_url="${container_remote_write_url//&/\\&}"
escaped_url="${escaped_url//|/\\|}"
sed -e "s|__INSTANCE_LABEL__|${INSTANCE_LABEL}|g" \
    -e "s|__REMOTE_WRITE_URL__|${escaped_url}|g" \
    prometheus.yml.tmpl > prometheus.yml

# 5. Pre-flight: confirm the central Prometheus has the remote-write receiver
#    enabled. If not, the agent will start but every push will 404.
say "checking central Prometheus at ${PROMETHEUS_URL} ..."
flags_json="$(curl -fsS --max-time 5 "${PROMETHEUS_URL}/api/v1/status/flags" 2>/dev/null || true)"
if [ -z "${flags_json}" ]; then
  warn "could not reach ${PROMETHEUS_URL}/api/v1/status/flags — is it up and reachable from this host?"
elif echo "${flags_json}" | grep -q '"web.enable-remote-write-receiver":"true"'; then
  say "central Prometheus has remote-write-receiver enabled."
else
  warn "central Prometheus is reachable but remote-write-receiver is NOT enabled."
  warn "ssh into the visualization host and run: gpu_monitor/central/enable-remote-write.sh"
fi

# 6. Bring containers up.
say "starting dcgm-exporter and prometheus-agent ..."
EXPORTER_PORT="${EXPORTER_PORT}" AGENT_PORT="${AGENT_PORT}" "${COMPOSE[@]}" up -d

# 7. Smoke-test the local metrics endpoints.
say "waiting for dcgm-exporter /metrics ..."
for i in {1..20}; do
  if curl -fsS "http://127.0.0.1:${EXPORTER_PORT}/metrics" -o /dev/null; then
    say "dcgm-exporter is live."
    break
  fi
  sleep 1
  [ "$i" = 20 ] && warn "dcgm-exporter did not respond after 20s — check 'docker compose logs dcgm-exporter'."
done

say "waiting for prometheus-agent /-/ready ..."
for i in {1..20}; do
  if curl -fsS "http://127.0.0.1:${AGENT_PORT}/-/ready" -o /dev/null; then
    say "prometheus-agent is ready."
    break
  fi
  sleep 1
  [ "$i" = 20 ] && warn "prometheus-agent did not become ready — check 'docker compose logs prometheus-agent'."
done

# 8. Confirm the agent has flushed at least one batch successfully.
#    prometheus_remote_storage_samples_total only increments on accepted samples.
say "checking remote_write delivery (this can take ~15s for the first scrape) ..."
sent_ok=0
for i in {1..6}; do
  metrics="$(curl -fsS "http://127.0.0.1:${AGENT_PORT}/metrics" 2>/dev/null || true)"
  sent="$(echo "${metrics}" | awk '/^prometheus_remote_storage_samples_total/{s+=$2} END{printf "%.0f", s+0}')"
  failed="$(echo "${metrics}" | awk '/^prometheus_remote_storage_samples_failed_total/{s+=$2} END{printf "%.0f", s+0}')"
  if [ "${sent:-0}" -gt 0 ] && [ "${failed:-0}" = "0" ]; then
    say "remote_write delivered ${sent} samples, 0 failures."
    sent_ok=1
    break
  fi
  if [ "${failed:-0}" -gt 0 ]; then
    warn "remote_write reporting ${failed} failed samples — receiver likely not enabled or URL wrong."
    break
  fi
  sleep 5
done

if [ "${sent_ok}" = 0 ]; then
  warn "no successful remote_write delivery confirmed yet — keep watching:"
  warn "  docker logs -f gpu-monitor-prometheus-agent"
fi

cat <<EOF

================================================================
  GPU push agent for instance '${INSTANCE_LABEL}' is up.

  Local checks:
    curl http://127.0.0.1:${EXPORTER_PORT}/metrics       # dcgm raw
    curl http://127.0.0.1:${AGENT_PORT}/-/ready          # agent
    docker logs -f gpu-monitor-prometheus-agent          # push log

  Verify in the central Prometheus:
    ${PROMETHEUS_URL}/graph?g0.expr=DCGM_FI_DEV_GPU_UTIL%7Binstance%3D%22${INSTANCE_LABEL}%22%7D

  Grafana:    ${GRAFANA_URL}
  Prometheus: ${PROMETHEUS_URL}
================================================================
EOF
