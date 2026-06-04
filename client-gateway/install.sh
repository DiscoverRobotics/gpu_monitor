#!/usr/bin/env bash
# One-click deployment of the GPU push agent on a cluster login node, where
# the compute nodes can reach the login node but NOT the central Prometheus.
#
# Topology:
#   compute0N (dcgm-exporter :9400) ──scrape──▶ login node (this script)
#                                                    │  remote_write
#                                                    ▼
#                                              central Prometheus
#
# Each compute node must already be running nvidia/dcgm-exporter and exposing
# /metrics on EXPORTER_PORT (default 9400). This script only sets up the
# prometheus-agent on the login node; it never tries to touch the compute
# nodes.
#
# Designed to be run via:
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/client-gateway/install.sh)" -- \
#     --PROMETHEUS_URL http://<server-host>:9090 \
#     --GRAFANA_URL    http://<server-host>:3000 \
#     --COMPUTE_NODES  compute01,compute02,compute03
#
# Materializes docker-compose.yml + prometheus.yml under ${INSTALL_DIR}
# (default: $(pwd)/gpu-monitor-gateway) and brings up:
#   - prom/prometheus (agent mode) on host network, scraping every compute
#     node's dcgm-exporter and remote_writing to the central Prometheus.
set -euo pipefail

EXPORTER_PORT="${EXPORTER_PORT:-9400}"
AGENT_PORT="${AGENT_PORT:-9091}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://43.133.11.173:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://43.133.11.173:3000}"
REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-}"
CLUSTER_LABEL="${CLUSTER_LABEL:-$(hostname)}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-15s}"
COMPUTE_NODES="${COMPUTE_NODES:-}"
COMPUTE_NODES_FILE="${COMPUTE_NODES_FILE:-}"
ALLOW_NO_NODES="${ALLOW_NO_NODES:-0}"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/gpu-monitor-gateway}"

usage() {
  cat <<EOF
Usage: install.sh [options]

Required (one or both):
  --COMPUTE_NODES <list>       Comma-separated [label=]host[:port] entries.
                               Examples:
                                 compute01,compute02,compute03
                                 gpu1=compute01:9400,gpu2=compute02
  --COMPUTE_NODES_FILE <path>  File with one [label=]host[:port] per line.
                               '#' comments and blank lines are ignored.
                               Merged with --COMPUTE_NODES if both are given.

Options:
  --PROMETHEUS_URL <url>   Server Prometheus base URL (default: ${PROMETHEUS_URL})
  --GRAFANA_URL    <url>   Server Grafana base URL    (default: ${GRAFANA_URL})
  --REMOTE_WRITE_URL <url> Override the push endpoint  (default: <PROMETHEUS_URL>/api/v1/write)
  --CLUSTER_LABEL  <name>  Label attached to every series as 'cluster' (default: \$(hostname))
  --SCRAPE_INTERVAL <dur>  Prometheus scrape_interval (default: ${SCRAPE_INTERVAL})
  --EXPORTER_PORT  <port>  Default exporter port when an entry omits it (default: ${EXPORTER_PORT})
  --AGENT_PORT     <port>  Host port for the agent UI on 127.0.0.1 (default: ${AGENT_PORT})
  --INSTALL_DIR    <dir>   Where to write compose + prometheus.yml (default: ${INSTALL_DIR})
  --ALLOW_NO_NODES         Continue even if zero compute nodes are reachable at pre-flight.
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
    --CLUSTER_LABEL)      CLUSTER_LABEL="$2"; shift 2 ;;
    --CLUSTER_LABEL=*)    CLUSTER_LABEL="${1#*=}"; shift ;;
    --SCRAPE_INTERVAL)    SCRAPE_INTERVAL="$2"; shift 2 ;;
    --SCRAPE_INTERVAL=*)  SCRAPE_INTERVAL="${1#*=}"; shift ;;
    --COMPUTE_NODES)      COMPUTE_NODES="$2"; shift 2 ;;
    --COMPUTE_NODES=*)    COMPUTE_NODES="${1#*=}"; shift ;;
    --COMPUTE_NODES_FILE) COMPUTE_NODES_FILE="$2"; shift 2 ;;
    --COMPUTE_NODES_FILE=*) COMPUTE_NODES_FILE="${1#*=}"; shift ;;
    --EXPORTER_PORT)      EXPORTER_PORT="$2"; shift 2 ;;
    --EXPORTER_PORT=*)    EXPORTER_PORT="${1#*=}"; shift ;;
    --AGENT_PORT)         AGENT_PORT="$2"; shift 2 ;;
    --AGENT_PORT=*)       AGENT_PORT="${1#*=}"; shift ;;
    --INSTALL_DIR)        INSTALL_DIR="$2"; shift 2 ;;
    --INSTALL_DIR=*)      INSTALL_DIR="${1#*=}"; shift ;;
    --ALLOW_NO_NODES)     ALLOW_NO_NODES=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-${PROMETHEUS_URL}/api/v1/write}"

say()   { printf '\033[1;36m[gateway]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[gateway]\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m[gateway]\033[0m %s\n' "$*" >&2; exit 1; }

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

# 2. Parse the compute-node list into parallel LABELS[] and ENDPOINTS[] arrays.
#    Each input entry is [label=]host[:port]; missing label -> host, missing port -> EXPORTER_PORT.
declare -a LABELS=()
declare -a ENDPOINTS=()
declare -A SEEN_LABELS=()

add_node() {
  local raw="$1" label host port hostport
  # strip leading/trailing whitespace
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [ -z "${raw}" ] && return 0
  case "${raw}" in
    \#*) return 0 ;;
  esac

  if [[ "${raw}" == *=* ]]; then
    label="${raw%%=*}"
    hostport="${raw#*=}"
  else
    label=""
    hostport="${raw}"
  fi

  if [[ "${hostport}" == *:* ]]; then
    host="${hostport%%:*}"
    port="${hostport#*:}"
  else
    host="${hostport}"
    port="${EXPORTER_PORT}"
  fi

  [ -z "${label}" ] && label="${host}"

  [[ -n "${host}" ]] || fail "compute-node entry has empty host: '${raw}'"
  [[ "${label}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || fail "compute-node label '${label}' is not safe for a Prometheus label value (allowed: [A-Za-z0-9._-]+)"
  [[ "${port}" =~ ^[0-9]+$ ]] \
    || fail "compute-node port '${port}' for '${label}' is not numeric"

  if [ -n "${SEEN_LABELS[${label}]+x}" ]; then
    fail "duplicate compute-node label '${label}' — labels must be unique"
  fi
  SEEN_LABELS[${label}]=1
  LABELS+=("${label}")
  ENDPOINTS+=("${host}:${port}")
}

if [ -n "${COMPUTE_NODES}" ]; then
  IFS=',' read -r -a __raw_entries <<<"${COMPUTE_NODES}"
  for entry in "${__raw_entries[@]}"; do
    add_node "${entry}"
  done
fi

if [ -n "${COMPUTE_NODES_FILE}" ]; then
  [ -r "${COMPUTE_NODES_FILE}" ] || fail "cannot read --COMPUTE_NODES_FILE '${COMPUTE_NODES_FILE}'"
  while IFS= read -r line || [ -n "${line}" ]; do
    add_node "${line}"
  done < "${COMPUTE_NODES_FILE}"
fi

if [ "${#LABELS[@]}" -eq 0 ]; then
  warn "no compute nodes provided — pass --COMPUTE_NODES and/or --COMPUTE_NODES_FILE."
  usage >&2
  exit 2
fi

say "parsed ${#LABELS[@]} compute node(s):"
for i in "${!LABELS[@]}"; do
  printf '         - %s -> %s\n' "${LABELS[$i]}" "${ENDPOINTS[$i]}"
done

# 3. Pre-flight: probe each compute node's /metrics. Warn per unreachable;
#    fail if *zero* are reachable unless --ALLOW_NO_NODES.
say "probing compute node exporters ..."
reachable=0
for i in "${!LABELS[@]}"; do
  if curl -fsS --max-time 3 "http://${ENDPOINTS[$i]}/metrics" -o /dev/null 2>/dev/null; then
    say "  ${LABELS[$i]} (${ENDPOINTS[$i]}) is reachable."
    reachable=$((reachable + 1))
  else
    warn "  ${LABELS[$i]} (${ENDPOINTS[$i]}) did NOT respond — agent will keep retrying."
  fi
done
if [ "${reachable}" -eq 0 ] && [ "${ALLOW_NO_NODES}" != "1" ]; then
  fail "zero compute nodes reachable from this login node — fix DNS/firewall or rerun with --ALLOW_NO_NODES."
fi

# 4. Pre-flight: confirm the server Prometheus has remote-write-receiver on.
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

# 5. Warn if remote_write target is loopback (only valid when central Prometheus
#    runs on this same login node — uncommon but possible).
case "${REMOTE_WRITE_URL}" in
  *://127.0.0.1:*|*://127.0.0.1/*|*://localhost:*|*://localhost/*)
    warn "remote_write target is loopback (${REMOTE_WRITE_URL}) — this only works if the central Prometheus is on this same login node."
    ;;
esac

# 6. Pre-flight: agent port must be free on the host.
port_busy() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :${p} )" 2>/dev/null | awk 'NR>1{found=1} END{exit !found}'
  elif command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "${p}" >/dev/null 2>&1
  else
    return 1
  fi
}
if port_busy "${AGENT_PORT}"; then
  fail "AGENT_PORT ${AGENT_PORT} is already bound on this host — pick another with --AGENT_PORT."
fi

# 7. Materialize config files.
say "writing config to ${INSTALL_DIR} (cluster=${CLUSTER_LABEL}, remote_write=${REMOTE_WRITE_URL}) ..."
mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

# Build the static_configs body once so the prometheus.yml heredoc can include it.
static_configs_body=""
for i in "${!LABELS[@]}"; do
  static_configs_body+="      - targets: [\"${ENDPOINTS[$i]}\"]"$'\n'
  static_configs_body+="        labels:"$'\n'
  static_configs_body+="          instance: ${LABELS[$i]}"$'\n'
done

cat > docker-compose.yml <<YAML
# Login-node gateway deployment — generated by install.sh; re-running overwrites this.
services:
  prometheus-agent:
    image: prom/prometheus:v2.55.0
    container_name: gpu-monitor-gw-prometheus-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prom-agent-data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --enable-feature=agent
      - --storage.agent.path=/prometheus
      - --web.listen-address=127.0.0.1:${AGENT_PORT}
    environment:
      - http_proxy=\${HTTP_PROXY:-}
      - https_proxy=\${HTTPS_PROXY:-}
      - no_proxy=\${NO_PROXY:-localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16}

volumes:
  prom-agent-data:
YAML

cat > prometheus.yml <<YAML
global:
  scrape_interval: ${SCRAPE_INTERVAL}
  scrape_timeout: 10s
  external_labels:
    cluster: ${CLUSTER_LABEL}

scrape_configs:
  - job_name: dcgm
    static_configs:
${static_configs_body}
remote_write:
  - url: ${REMOTE_WRITE_URL}
    queue_config:
      max_samples_per_send: 1000
      capacity: 10000
      batch_send_deadline: 5s
    write_relabel_configs:
      - source_labels: [__name__]
        regex: "DCGM_.*"
        action: keep
YAML

# 8. Bring the agent up.
say "starting prometheus-agent ..."
AGENT_PORT="${AGENT_PORT}" "${COMPOSE[@]}" up -d

# 9. Wait for /-/ready.
say "waiting for prometheus-agent /-/ready ..."
agent_ready=0
for i in {1..20}; do
  if curl -fsS "http://127.0.0.1:${AGENT_PORT}/-/ready" -o /dev/null 2>/dev/null; then
    say "prometheus-agent is ready."
    agent_ready=1
    break
  fi
  sleep 1
done
[ "${agent_ready}" = 1 ] \
  || warn "prometheus-agent did not become ready after 20s — check 'docker logs -f gpu-monitor-gw-prometheus-agent'."

# 10. Report scrape-target health in aggregate.
say "checking scrape-target health (give it a few seconds for the first scrape) ..."
sleep 3
targets_json="$(curl -fsS "http://127.0.0.1:${AGENT_PORT}/api/v1/targets" 2>/dev/null || true)"
if [ -n "${targets_json}" ]; then
  total="${#LABELS[@]}"
  up_count=$(echo "${targets_json}" | grep -o '"health":"up"' | wc -l | tr -d ' ')
  if [ "${up_count}" -ge "${total}" ]; then
    say "  targets up: ${up_count}/${total}"
  else
    warn "  targets up: ${up_count}/${total} — inspect 'curl http://127.0.0.1:${AGENT_PORT}/api/v1/targets' for the failing ones."
  fi
else
  warn "could not query /api/v1/targets — agent may still be coming up."
fi

# 11. Confirm at least one batch has flushed successfully.
say "checking remote_write delivery (this can take ~${SCRAPE_INTERVAL} for the first scrape) ..."
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
  warn "  docker logs -f gpu-monitor-gw-prometheus-agent"
fi

# 12. Final banner.
node_list=""
for i in "${!LABELS[@]}"; do
  node_list+="    ${LABELS[$i]} -> ${ENDPOINTS[$i]}"$'\n'
done

cat <<EOF

================================================================
  GPU push gateway for cluster '${CLUSTER_LABEL}' is up.

  Install dir: ${INSTALL_DIR}

  Compute nodes scraped:
${node_list}
  Local checks:
    curl http://127.0.0.1:${AGENT_PORT}/-/ready          # agent
    curl http://127.0.0.1:${AGENT_PORT}/api/v1/targets   # per-node health
    docker logs -f gpu-monitor-gw-prometheus-agent       # push log

  Verify in the server Prometheus:
    ${PROMETHEUS_URL}/graph?g0.expr=DCGM_FI_DEV_GPU_UTIL%7Bcluster%3D%22${CLUSTER_LABEL}%22%7D

  Grafana:    ${GRAFANA_URL}
  Prometheus: ${PROMETHEUS_URL}
================================================================
EOF
