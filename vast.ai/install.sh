#!/usr/bin/env bash
# One-click deployment of the vast.ai Prometheus exporter on any host
# (no GPU required — the exporter only talks to the vast.ai REST API).
#
# Designed to be run via:
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/vast.ai/install.sh)" -- \
#     --VAST_API_KEY    <your_vast_ai_api_key> \
#     --PROMETHEUS_URL  http://<server-host>:9090 \
#     --GRAFANA_URL     http://<server-host>:3000
#
# Materializes Dockerfile + exporter.py + requirements.txt (if not already
# present locally) + docker-compose.yml + prometheus.yml under
# ${INSTALL_DIR} (default: $(pwd)/gpu-monitor-vastai) and brings up:
#   - vastai-exporter    on :${EXPORTER_PORT:-9401} (compose-internal)
#   - prom/prometheus    (agent mode) scraping the exporter and
#     remote_writing samples to the server Prometheus.
set -euo pipefail

EXPORTER_PORT="${EXPORTER_PORT:-9401}"
AGENT_PORT="${AGENT_PORT:-9092}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://43.133.11.173:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://43.133.11.173:3000}"
REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-}"
INSTANCE_LABEL="${INSTANCE_LABEL:-vastai-$(hostname)}"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/gpu-monitor-vastai}"
VAST_API_KEY="${VAST_API_KEY:-${VASTAI_API_KEY:-}}"
VAST_API_URL="${VAST_API_URL:-https://console.vast.ai/api/v0}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-30}"
VASTAI_EXPORTER_IMAGE="${VASTAI_EXPORTER_IMAGE:-gpu-monitor-vastai-exporter:latest}"
SKIP_USER="${SKIP_USER:-0}"
GITHUB_RAW="${GITHUB_RAW:-https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/vast.ai}"
SOURCE_DIR="${SOURCE_DIR:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"

usage() {
  cat <<EOF
Usage: install.sh [options]

Required:
  --VAST_API_KEY    <key>  vast.ai API key (or env VAST_API_KEY / VASTAI_API_KEY).
                           Get one at https://cloud.vast.ai/cli/

Options:
  --PROMETHEUS_URL        <url>   Server Prometheus base URL (default: ${PROMETHEUS_URL})
  --GRAFANA_URL           <url>   Server Grafana base URL    (default: ${GRAFANA_URL})
  --REMOTE_WRITE_URL      <url>   Override the push endpoint  (default: <PROMETHEUS_URL>/api/v1/write)
  --INSTANCE_LABEL        <name>  Label attached to every series (default: ${INSTANCE_LABEL})
  --EXPORTER_PORT         <port>  Host port for vastai-exporter (default: ${EXPORTER_PORT})
  --AGENT_PORT            <port>  Host port for the agent UI   (default: ${AGENT_PORT})
  --SCRAPE_INTERVAL       <sec>   Exporter cache TTL between vast.ai API calls (default: ${SCRAPE_INTERVAL})
  --VAST_API_URL          <url>   Override vast.ai API base   (default: ${VAST_API_URL})
  --VASTAI_EXPORTER_IMAGE <tag>   Image tag to use/build      (default: ${VASTAI_EXPORTER_IMAGE})
  --SOURCE_DIR            <dir>   Pre-existing dir containing exporter.py + Dockerfile (default: autodetect)
  --GITHUB_RAW            <url>   Base URL to fetch sources if not local (default: ${GITHUB_RAW})
  --INSTALL_DIR           <dir>   Where to write compose + configs (default: ${INSTALL_DIR})
  --SKIP_BUILD                    Use --VASTAI_EXPORTER_IMAGE as-is, do not build
  --SKIP_USER                     Disable /users/current/ poll (set if your key lacks the scope)
  -h, --help                      Show this help

Environment variables of the same name are honoured as fallbacks; CLI flags win.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --VAST_API_KEY)            VAST_API_KEY="$2"; shift 2 ;;
    --VAST_API_KEY=*)          VAST_API_KEY="${1#*=}"; shift ;;
    --VAST_API_URL)            VAST_API_URL="$2"; shift 2 ;;
    --VAST_API_URL=*)          VAST_API_URL="${1#*=}"; shift ;;
    --PROMETHEUS_URL)          PROMETHEUS_URL="$2"; shift 2 ;;
    --PROMETHEUS_URL=*)        PROMETHEUS_URL="${1#*=}"; shift ;;
    --GRAFANA_URL)             GRAFANA_URL="$2"; shift 2 ;;
    --GRAFANA_URL=*)           GRAFANA_URL="${1#*=}"; shift ;;
    --REMOTE_WRITE_URL)        REMOTE_WRITE_URL="$2"; shift 2 ;;
    --REMOTE_WRITE_URL=*)      REMOTE_WRITE_URL="${1#*=}"; shift ;;
    --INSTANCE_LABEL)          INSTANCE_LABEL="$2"; shift 2 ;;
    --INSTANCE_LABEL=*)        INSTANCE_LABEL="${1#*=}"; shift ;;
    --EXPORTER_PORT)           EXPORTER_PORT="$2"; shift 2 ;;
    --EXPORTER_PORT=*)         EXPORTER_PORT="${1#*=}"; shift ;;
    --AGENT_PORT)              AGENT_PORT="$2"; shift 2 ;;
    --AGENT_PORT=*)            AGENT_PORT="${1#*=}"; shift ;;
    --SCRAPE_INTERVAL)         SCRAPE_INTERVAL="$2"; shift 2 ;;
    --SCRAPE_INTERVAL=*)       SCRAPE_INTERVAL="${1#*=}"; shift ;;
    --VASTAI_EXPORTER_IMAGE)   VASTAI_EXPORTER_IMAGE="$2"; shift 2 ;;
    --VASTAI_EXPORTER_IMAGE=*) VASTAI_EXPORTER_IMAGE="${1#*=}"; shift ;;
    --SOURCE_DIR)              SOURCE_DIR="$2"; shift 2 ;;
    --SOURCE_DIR=*)            SOURCE_DIR="${1#*=}"; shift ;;
    --GITHUB_RAW)              GITHUB_RAW="$2"; shift 2 ;;
    --GITHUB_RAW=*)            GITHUB_RAW="${1#*=}"; shift ;;
    --INSTALL_DIR)             INSTALL_DIR="$2"; shift 2 ;;
    --INSTALL_DIR=*)           INSTALL_DIR="${1#*=}"; shift ;;
    --SKIP_BUILD)              SKIP_BUILD=1; shift ;;
    --SKIP_USER)               SKIP_USER=1; shift ;;
    -h|--help)                 usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-${PROMETHEUS_URL}/api/v1/write}"

say()   { printf '\033[1;36m[vastai]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[vastai]\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m[vastai]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "${VAST_API_KEY}" ] \
  || fail "missing --VAST_API_KEY (or env VAST_API_KEY / VASTAI_API_KEY). Get one at https://cloud.vast.ai/cli/"

# 1. Docker — auto-install if missing.
install_docker() {
  say "docker not found — installing via official convenience script ..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh --mirror Aliyun
  rm -f /tmp/get-docker.sh
  if [ "$(id -u)" -ne 0 ] && ! groups | grep -qw docker; then
    sudo usermod -aG docker "$(whoami)" || true
  fi
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now docker
  fi
  command -v docker >/dev/null 2>&1 \
    || fail "docker installation failed — please install manually: https://docs.docker.com/engine/install/"
  say "docker installed successfully."
}

install_docker_compose() {
  say "docker compose not found — installing the v2 plugin ..."
  local compose_version="v2.29.2"
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) fail "unsupported architecture: ${arch}" ;;
  esac
  local dest="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"
  mkdir -p "${dest}"
  curl -fsSL "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-linux-${arch}" \
    -o "${dest}/docker-compose"
  chmod +x "${dest}/docker-compose"
  docker compose version >/dev/null 2>&1 \
    || fail "docker compose installation failed — please install manually: https://docs.docker.com/compose/install/"
  say "docker compose installed successfully."
}

command -v docker >/dev/null 2>&1 || install_docker

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  install_docker_compose
  COMPOSE=(docker compose)
fi

# 2. Locate or fetch exporter sources, then build the image.
autodetect_source_dir() {
  local candidates=(
    "$(pwd)/vast.ai"
    "$(pwd)"
  )
  # Also try the directory containing this script, when invoked locally.
  case "${BASH_SOURCE[0]:-}" in
    /*) candidates+=("$(dirname "${BASH_SOURCE[0]}")") ;;
    ./*|*/*) candidates+=("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)") ;;
  esac
  for c in "${candidates[@]}"; do
    if [ -f "${c}/Dockerfile" ] && [ -f "${c}/exporter.py" ] && [ -f "${c}/requirements.txt" ]; then
      printf '%s' "${c}"
      return 0
    fi
  done
  return 1
}

if [ "${SKIP_BUILD}" = "1" ]; then
  say "skip-build mode — using image ${VASTAI_EXPORTER_IMAGE} as-is."
  docker image inspect "${VASTAI_EXPORTER_IMAGE}" >/dev/null 2>&1 || {
    say "image not present locally — pulling ${VASTAI_EXPORTER_IMAGE} ..."
    docker pull "${VASTAI_EXPORTER_IMAGE}" \
      || fail "could not pull ${VASTAI_EXPORTER_IMAGE} and --SKIP_BUILD was set."
  }
else
  if [ -z "${SOURCE_DIR}" ]; then
    SOURCE_DIR="$(autodetect_source_dir || true)"
  fi
  if [ -z "${SOURCE_DIR}" ]; then
    SOURCE_DIR="$(mktemp -d -t vastai-exporter-XXXXXX)"
    say "downloading exporter sources from ${GITHUB_RAW} into ${SOURCE_DIR} ..."
    for f in Dockerfile exporter.py requirements.txt; do
      curl -fsSL "${GITHUB_RAW}/${f}" -o "${SOURCE_DIR}/${f}" \
        || fail "failed to fetch ${GITHUB_RAW}/${f}"
    done
  else
    say "using local exporter sources at ${SOURCE_DIR}."
  fi
  say "building ${VASTAI_EXPORTER_IMAGE} from ${SOURCE_DIR} ..."
  docker build -t "${VASTAI_EXPORTER_IMAGE}" "${SOURCE_DIR}" \
    || fail "docker build failed."
fi

# 3. Rewrite localhost in remote_write so the agent container can reach the host.
container_remote_write_url="${REMOTE_WRITE_URL}"
case "${container_remote_write_url}" in
  *://127.0.0.1:*|*://127.0.0.1/*|*://localhost:*|*://localhost/*)
    container_remote_write_url="$(echo "${REMOTE_WRITE_URL}" \
      | sed -E 's#://(127\.0\.0\.1|localhost)([:/])#://host.docker.internal\2#')"
    say "rewriting agent's remote_write target to ${container_remote_write_url} (so the container can reach the host)."
    ;;
esac

# 4. Materialize compose + prometheus config.
say "writing config to ${INSTALL_DIR} (instance=${INSTANCE_LABEL}, remote_write=${container_remote_write_url}) ..."
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

EXPORTER_USER_FLAG=""
if [ "${SKIP_USER}" = "1" ]; then
  EXPORTER_USER_FLAG="--no-user"
fi

cat > docker-compose.yml <<YAML
# vast.ai exporter deployment — generated by install.sh; re-running overwrites this.
services:
  vastai-exporter:
    image: ${VASTAI_EXPORTER_IMAGE}
    container_name: gpu-monitor-vastai-exporter
    restart: unless-stopped
    environment:
      VASTAI_API_KEY: "\${VASTAI_API_KEY}"
      VASTAI_API_URL: "\${VASTAI_API_URL}"
      VASTAI_SCRAPE_INTERVAL: "\${VASTAI_SCRAPE_INTERVAL}"
      VASTAI_LISTEN_ADDRESS: ":9401"
    command:
      - "--api-key=\${VASTAI_API_KEY}"
      - "--api-url=\${VASTAI_API_URL}"
      - "--scrape-interval=\${VASTAI_SCRAPE_INTERVAL}"
      - "--listen-address=:9401"
${EXPORTER_USER_FLAG:+"      - \"${EXPORTER_USER_FLAG}\""}
    ports:
      - "\${EXPORTER_PORT:-9401}:9401"

  prometheus-agent:
    image: prom/prometheus:v2.55.0
    container_name: gpu-monitor-vastai-prometheus-agent
    restart: unless-stopped
    depends_on:
      - vastai-exporter
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
      - "127.0.0.1:\${AGENT_PORT:-9092}:9091"
    environment:
      - http_proxy=\${HTTP_PROXY:-}
      - https_proxy=\${HTTPS_PROXY:-}
      - no_proxy=localhost,127.0.0.1,vastai-exporter,host.docker.internal

volumes:
  prom-agent-data:
YAML

cat > prometheus.yml <<YAML
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  external_labels:
    instance: ${INSTANCE_LABEL}
    source: vastai

scrape_configs:
  - job_name: vastai
    static_configs:
      - targets: ["vastai-exporter:9401"]
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
        regex: "vastai_.*"
        action: keep
YAML

# 5. Pre-flight: confirm the server Prometheus has the remote-write receiver
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

# 6. Bring containers up.
say "starting vastai-exporter and prometheus-agent ..."
EXPORTER_PORT="${EXPORTER_PORT}" \
AGENT_PORT="${AGENT_PORT}" \
VASTAI_API_KEY="${VAST_API_KEY}" \
VASTAI_API_URL="${VAST_API_URL}" \
VASTAI_SCRAPE_INTERVAL="${SCRAPE_INTERVAL}" \
  "${COMPOSE[@]}" up -d

# 7. Smoke-test local endpoints.
say "waiting for vastai-exporter /metrics on :${EXPORTER_PORT} ..."
exp_ok=0
for i in {1..30}; do
  if curl -fsS --max-time 2 "http://127.0.0.1:${EXPORTER_PORT}/metrics" -o /dev/null; then
    exp_ok=1
    say "vastai-exporter is live."
    break
  fi
  sleep 1
done
[ "${exp_ok}" = 1 ] || warn "vastai-exporter did not respond after 30s — check 'docker logs gpu-monitor-vastai-exporter'."

if [ "${exp_ok}" = 1 ]; then
  scrape_ok="$(curl -fsS --max-time 5 "http://127.0.0.1:${EXPORTER_PORT}/metrics" 2>/dev/null \
    | awk '/^vastai_scrape_success\{endpoint="instances"\}/ {print $2}' | tail -n1)"
  if [ "${scrape_ok:-0}" = "1" ] || [ "${scrape_ok:-0}" = "1.0" ]; then
    say "vast.ai /instances/ call succeeded."
  else
    warn "vastai_scrape_success{endpoint=\"instances\"} is not 1 — check the API key and 'docker logs gpu-monitor-vastai-exporter'."
  fi
fi

say "waiting for prometheus-agent /-/ready on 127.0.0.1:${AGENT_PORT} ..."
agent_ok=0
for i in {1..30}; do
  if curl -fsS --max-time 2 "http://127.0.0.1:${AGENT_PORT}/-/ready" -o /dev/null; then
    agent_ok=1
    say "prometheus-agent is ready."
    break
  fi
  sleep 1
done
[ "${agent_ok}" = 1 ] || warn "prometheus-agent did not become ready — check 'docker logs gpu-monitor-vastai-prometheus-agent'."

# 8. Confirm at least one remote_write batch landed successfully.
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
  warn "  docker logs -f gpu-monitor-vastai-prometheus-agent"
fi

cat <<EOF

================================================================
  vast.ai exporter for instance '${INSTANCE_LABEL}' is up.

  Install dir: ${INSTALL_DIR}
  Image:       ${VASTAI_EXPORTER_IMAGE}

  Local checks:
    curl http://127.0.0.1:${EXPORTER_PORT}/metrics       # vastai raw
    curl http://127.0.0.1:${AGENT_PORT}/-/ready           # agent
    docker logs -f gpu-monitor-vastai-exporter            # exporter log
    docker logs -f gpu-monitor-vastai-prometheus-agent    # push log

  Verify in the server Prometheus:
    ${PROMETHEUS_URL}/graph?g0.expr=vastai_instance_gpu_util_percent%7Binstance%3D%22${INSTANCE_LABEL}%22%7D

  Grafana:    ${GRAFANA_URL}
  Prometheus: ${PROMETHEUS_URL}
================================================================
EOF
