#!/usr/bin/env bash
# One-click deployment of the GPU push agent on a GPU host behind NAT.
#
# Designed to be run via:
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/client/install.sh)" -- \
#     --PROMETHEUS_URL http://<server-host>:9090 \
#     --GRAFANA_URL    http://<server-host>:3000
#
# Materializes docker-compose.yml + prometheus.yml under ${INSTALL_DIR}
# (default: $(pwd)/gpu-monitor-client) and brings up:
#   - nvidia/dcgm-exporter on :9400 (compose-internal)
#   - prom/prometheus (agent mode) that scrapes dcgm-exporter and
#     remote_writes samples to the server Prometheus.
set -euo pipefail

EXPORTER_PORT="${EXPORTER_PORT:-9400}"
AGENT_PORT="${AGENT_PORT:-9091}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://43.133.11.173:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://43.133.11.173:3000}"
REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-}"
INSTANCE_LABEL="${INSTANCE_LABEL:-$(hostname)}"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/gpu-monitor-client}"

usage() {
  cat <<EOF
Usage: install.sh [options]

Options:
  --PROMETHEUS_URL <url>   Server Prometheus base URL (default: ${PROMETHEUS_URL})
  --GRAFANA_URL    <url>   Server Grafana base URL    (default: ${GRAFANA_URL})
  --REMOTE_WRITE_URL <url> Override the push endpoint  (default: <PROMETHEUS_URL>/api/v1/write)
  --INSTANCE_LABEL <name>  Label attached to every series (default: \$(hostname))
  --EXPORTER_PORT  <port>  Host port for dcgm-exporter  (default: ${EXPORTER_PORT})
  --AGENT_PORT     <port>  Host port for the agent UI   (default: ${AGENT_PORT})
  --INSTALL_DIR    <dir>   Where to write compose + prometheus.yml (default: ${INSTALL_DIR})
  -h, --help               Show this help

Environment variables of the same name are honoured as fallbacks; CLI flags win.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --PROMETHEUS_URL)     PROMETHEUS_URL="$2"; shift 2 ;;
    --PROMETHEUS_URL=*)   PROMETHEUS_URL="${1#*=}"; shift ;;
    --GRAFANA_URL)        GRAFANA_URL="$2"; shift 2 ;;
    --GRAFANA_URL=*)      GRAFANA_URL="${1#*=}"; shift ;;
    --REMOTE_WRITE_URL)   REMOTE_WRITE_URL="$2"; shift 2 ;;
    --REMOTE_WRITE_URL=*) REMOTE_WRITE_URL="${1#*=}"; shift ;;
    --INSTANCE_LABEL)     INSTANCE_LABEL="$2"; shift 2 ;;
    --INSTANCE_LABEL=*)   INSTANCE_LABEL="${1#*=}"; shift ;;
    --EXPORTER_PORT)      EXPORTER_PORT="$2"; shift 2 ;;
    --EXPORTER_PORT=*)    EXPORTER_PORT="${1#*=}"; shift ;;
    --AGENT_PORT)         AGENT_PORT="$2"; shift 2 ;;
    --AGENT_PORT=*)       AGENT_PORT="${1#*=}"; shift ;;
    --INSTALL_DIR)        INSTALL_DIR="$2"; shift 2 ;;
    --INSTALL_DIR=*)      INSTALL_DIR="${1#*=}"; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-${PROMETHEUS_URL}/api/v1/write}"

say()   { printf '\033[1;36m[client]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[client]\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m[client]\033[0m %s\n' "$*" >&2; exit 1; }

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

# 4. Inside the container, 127.0.0.1/localhost would resolve to the container
#    itself, not the host running the server stack. Rewrite to host.docker.internal
#    (mapped via extra_hosts) only for the agent's config — host-side probes
#    below still use the URL as supplied.
container_remote_write_url="${REMOTE_WRITE_URL}"
case "${container_remote_write_url}" in
  *://127.0.0.1:*|*://127.0.0.1/*|*://localhost:*|*://localhost/*)
    container_remote_write_url="$(echo "${REMOTE_WRITE_URL}" \
      | sed -E 's#://(127\.0\.0\.1|localhost)([:/])#://host.docker.internal\2#')"
    say "rewriting agent's remote_write target to ${container_remote_write_url} (so the container can reach the host)."
    ;;
esac

# 5. Materialize config files.
say "writing config to ${INSTALL_DIR} (instance=${INSTANCE_LABEL}, remote_write=${container_remote_write_url}) ..."
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

cat > docker-compose.yml <<'YAML'
# GPU node (client) deployment — generated by install.sh; re-running overwrites this.
services:
  dcgm-exporter:
    image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.1-ubuntu22.04
    container_name: gpu-monitor-dcgm-exporter
    restart: unless-stopped
    cap_add:
      - SYS_ADMIN
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu, utility]
    ports:
      - "${EXPORTER_PORT:-9400}:9400"
    environment:
      DCGM_EXPORTER_LISTEN: ":9400"
      DCGM_EXPORTER_KUBERNETES: "false"

  prometheus-agent:
    image: prom/prometheus:v2.55.0
    container_name: gpu-monitor-prometheus-agent
    restart: unless-stopped
    depends_on:
      - dcgm-exporter
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prom-agent-data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --enable-feature=agent
      - --storage.agent.path=/prometheus
      - --web.listen-address=:9091
    ports:
      - "127.0.0.1:${AGENT_PORT:-9091}:9091"

volumes:
  prom-agent-data:
YAML

cat > prometheus.yml <<YAML
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  external_labels:
    instance: ${INSTANCE_LABEL}

scrape_configs:
  - job_name: dcgm
    static_configs:
      - targets: ["dcgm-exporter:9400"]
        labels:
          instance: ${INSTANCE_LABEL}

remote_write:
  - url: ${container_remote_write_url}
    queue_config:
      max_samples_per_send: 1000
      capacity: 10000
      batch_send_deadline: 5s
    write_relabel_configs:
      - source_labels: [__name__]
        regex: "DCGM_.*"
        action: keep
YAML

# 6. Pre-flight: confirm the server Prometheus has the remote-write receiver
#    enabled. If not, the agent will start but every push will 404.
say "checking server Prometheus at ${PROMETHEUS_URL} ..."
flags_json="$(curl -fsS --max-time 5 "${PROMETHEUS_URL}/api/v1/status/flags" 2>/dev/null || true)"
if [ -z "${flags_json}" ]; then
  warn "could not reach ${PROMETHEUS_URL}/api/v1/status/flags — is it up and reachable from this host?"
elif echo "${flags_json}" | grep -q '"web.enable-remote-write-receiver":"true"'; then
  say "server Prometheus has remote-write-receiver enabled."
else
  warn "server Prometheus is reachable but remote-write-receiver is NOT enabled."
  warn "redeploy the server with the install.sh in this repo — it sets the flag by default."
fi

# 7. Bring containers up.
say "starting dcgm-exporter and prometheus-agent ..."
EXPORTER_PORT="${EXPORTER_PORT}" AGENT_PORT="${AGENT_PORT}" "${COMPOSE[@]}" up -d

# 8. Smoke-test the local metrics endpoints.
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

# 9. Confirm the agent has flushed at least one batch successfully.
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

  Install dir: ${INSTALL_DIR}

  Local checks:
    curl http://127.0.0.1:${EXPORTER_PORT}/metrics       # dcgm raw
    curl http://127.0.0.1:${AGENT_PORT}/-/ready          # agent
    docker logs -f gpu-monitor-prometheus-agent          # push log

  Verify in the server Prometheus:
    ${PROMETHEUS_URL}/graph?g0.expr=DCGM_FI_DEV_GPU_UTIL%7Binstance%3D%22${INSTANCE_LABEL}%22%7D

  Grafana:    ${GRAFANA_URL}
  Prometheus: ${PROMETHEUS_URL}
================================================================
EOF
