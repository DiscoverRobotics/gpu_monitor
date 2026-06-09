#!/usr/bin/env bash
# One-click deployment of the GPU push agent on a cluster login node, where
# the compute nodes can reach the login node but NOT the central Prometheus,
# AND the login node has no docker / no sudo. The Prometheus binary is
# downloaded into ${INSTALL_DIR} and run as a plain background process
# (nohup + PID file). No system packages, no containers, no root.
#
# Topology:
#   compute0N (dcgm-exporter :9400) ──scrape──▶ login node (this script)
#                                                    │  remote_write
#                                                    ▼
#                                              central Prometheus
#
# Each compute node must already be running nvidia/dcgm-exporter and
# exposing /metrics on EXPORTER_PORT (default 9400). This script only sets
# up the prometheus-agent on the login node; it never touches the compute
# nodes.
#
# Designed to be run via:
#   sh -c "$(curl -fsSL https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/client-gateway/install.sh)" -- \
#     --PROMETHEUS_URL http://<server-host>:9090 \
#     --GRAFANA_URL    http://<server-host>:3000 \
#     --COMPUTE_NODES  compute01,compute02,compute03
#
# Materializes ${INSTALL_DIR}/prometheus, ${INSTALL_DIR}/prometheus.yml, and
# launches the agent in the background. Re-running this script gracefully
# stops the existing process before starting the new one.
#
# Sub-commands:
#   install.sh --STOP        Stop the running agent and exit.
#   install.sh --STATUS      Report whether the agent is running and exit.
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
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-2.55.0}"
PROMETHEUS_DOWNLOAD_BASE="${PROMETHEUS_DOWNLOAD_BASE:-https://github.com/prometheus/prometheus/releases/download}"
# Offline / pre-staged binary support: the login node is the only host with
# outbound access, so when the release download is blocked you can drop a
# binary (or release tarball) next to the script and point these at it.
PROMETHEUS_BINARY="${PROMETHEUS_BINARY:-}"
PROMETHEUS_TARBALL="${PROMETHEUS_TARBALL:-}"
ACTION="install"

usage() {
  cat <<EOF
Usage: install.sh [options]
       install.sh --STOP
       install.sh --STATUS

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
  --INSTALL_DIR    <dir>   Where to install + run the agent (default: ${INSTALL_DIR})
  --PROMETHEUS_VERSION <v> Prometheus release to download (default: ${PROMETHEUS_VERSION})
  --PROMETHEUS_BINARY <p>  Use a pre-staged prometheus binary instead of downloading
                           (e.g. one you copied to this login node manually).
  --PROMETHEUS_TARBALL <p> Extract a pre-staged release tarball instead of downloading.
  --PROMETHEUS_DOWNLOAD_BASE <url>
                           Release mirror base (default: ${PROMETHEUS_DOWNLOAD_BASE})
  --ALLOW_NO_NODES         Continue even if zero compute nodes are reachable at pre-flight.
  --STOP                   Stop the running agent and exit.
  --STATUS                 Report agent status (running/stopped) and exit.
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
    --PROMETHEUS_VERSION) PROMETHEUS_VERSION="$2"; shift 2 ;;
    --PROMETHEUS_VERSION=*) PROMETHEUS_VERSION="${1#*=}"; shift ;;
    --PROMETHEUS_BINARY)  PROMETHEUS_BINARY="$2"; shift 2 ;;
    --PROMETHEUS_BINARY=*) PROMETHEUS_BINARY="${1#*=}"; shift ;;
    --PROMETHEUS_TARBALL) PROMETHEUS_TARBALL="$2"; shift 2 ;;
    --PROMETHEUS_TARBALL=*) PROMETHEUS_TARBALL="${1#*=}"; shift ;;
    --PROMETHEUS_DOWNLOAD_BASE) PROMETHEUS_DOWNLOAD_BASE="$2"; shift 2 ;;
    --PROMETHEUS_DOWNLOAD_BASE=*) PROMETHEUS_DOWNLOAD_BASE="${1#*=}"; shift ;;
    --ALLOW_NO_NODES)     ALLOW_NO_NODES=1; shift ;;
    --STOP)               ACTION="stop"; shift ;;
    --STATUS)             ACTION="status"; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

REMOTE_WRITE_URL="${REMOTE_WRITE_URL:-${PROMETHEUS_URL}/api/v1/write}"

say()   { printf '\033[1;36m[gateway]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[gateway]\033[0m %s\n' "$*" >&2; }
fail()  { printf '\033[1;31m[gateway]\033[0m %s\n' "$*" >&2; exit 1; }

# Extract the bare host from a URL (drop scheme, path, userinfo, port).
url_host() {
  local u="$1"
  u="${u#*://}"   # strip scheme://
  u="${u%%/*}"    # strip /path
  u="${u##*@}"    # strip user:pass@
  u="${u%%:*}"    # strip :port
  printf '%s' "${u}"
}

PID_FILE="${INSTALL_DIR}/prometheus.pid"
LOG_FILE="${INSTALL_DIR}/prometheus.log"
DATA_DIR="${INSTALL_DIR}/data"
CONFIG_FILE="${INSTALL_DIR}/prometheus.yml"
BIN="${INSTALL_DIR}/prometheus"

agent_pid() {
  [ -f "${PID_FILE}" ] || return 1
  local pid
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  printf '%s' "${pid}"
}

stop_agent() {
  local pid
  if pid="$(agent_pid)"; then
    say "stopping prometheus-agent (pid=${pid}) ..."
    kill "${pid}" 2>/dev/null || true
    local waited=0
    while kill -0 "${pid}" 2>/dev/null; do
      sleep 0.5
      waited=$((waited + 1))
      if [ "${waited}" -ge 20 ]; then
        warn "agent did not exit after 10s — sending SIGKILL."
        kill -9 "${pid}" 2>/dev/null || true
        break
      fi
    done
    rm -f "${PID_FILE}"
    say "prometheus-agent stopped."
  else
    say "no running prometheus-agent."
    rm -f "${PID_FILE}"
  fi
}

# Sub-command short-circuits.
case "${ACTION}" in
  stop)
    stop_agent
    exit 0
    ;;
  status)
    if pid="$(agent_pid)"; then
      say "prometheus-agent running (pid=${pid})."
      say "  UI:       http://127.0.0.1:${AGENT_PORT}"
      say "  Log:      ${LOG_FILE}"
      say "  Config:   ${CONFIG_FILE}"
      exit 0
    else
      say "prometheus-agent is not running."
      exit 1
    fi
    ;;
esac

# 1. Sanity-check the runtime prerequisites — pure userland, no sudo / no docker.
for cmd in curl tar awk; do
  command -v "${cmd}" >/dev/null 2>&1 || fail "required command '${cmd}' not found in PATH"
done

# 2. Parse the compute-node list into parallel LABELS[] and ENDPOINTS[] arrays.
#    Each input entry is [label=]host[:port]; missing label -> host, missing port -> EXPORTER_PORT.
declare -a LABELS=()
declare -a ENDPOINTS=()
declare -A SEEN_LABELS=()

add_node() {
  local raw="$1" label host port hostport
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
#    fail if zero are reachable unless --ALLOW_NO_NODES.
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

# 5. Pre-flight: agent port must be free (after we account for any already-running
#    instance owned by this script — we'll stop that below before binding).
existing_pid=""
if existing_pid="$(agent_pid)"; then
  say "found existing prometheus-agent (pid=${existing_pid}) — will stop and restart with the new config."
else
  existing_pid=""
fi

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

if [ -z "${existing_pid}" ] && port_busy "${AGENT_PORT}"; then
  fail "AGENT_PORT ${AGENT_PORT} is already bound by some other process — pick another with --AGENT_PORT."
fi

# 6. Layout the install dir.
say "preparing install dir ${INSTALL_DIR} ..."
mkdir -p "${INSTALL_DIR}" "${DATA_DIR}"

# 7. Obtain the Prometheus binary. Resolution order, first match wins:
#      a) --PROMETHEUS_BINARY <path>   use a pre-staged binary as-is
#      b) --PROMETHEUS_TARBALL <path>  extract a pre-staged release tarball
#      c) existing ${BIN} of matching version  reuse
#      d) download the release tarball from PROMETHEUS_DOWNLOAD_BASE
detect_arch() {
  local m
  m="$(uname -m)"
  case "${m}" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    *) fail "unsupported architecture: ${m}" ;;
  esac
}

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "${os}" in
  linux|darwin) ;;
  *) fail "unsupported OS: ${os}" ;;
esac
arch="$(detect_arch)"

# Pull the prometheus binary out of an extracted release tree and install it.
install_from_tarball() {
  local tb="$1" td extracted bin
  td="$(mktemp -d)"
  if ! tar -xzf "${tb}" -C "${td}" 2>/dev/null; then
    rm -rf "${td}"
    fail "failed to extract '${tb}' — is it a prometheus release tar.gz for ${os}-${arch}?"
  fi
  # Prefer the canonical path, but fall back to a recursive search so a
  # differently-named tarball still works.
  extracted="${td}/prometheus-${PROMETHEUS_VERSION}.${os}-${arch}/prometheus"
  if [ ! -x "${extracted}" ]; then
    extracted="$(find "${td}" -type f -name prometheus 2>/dev/null | head -n1)"
  fi
  [ -n "${extracted}" ] && [ -f "${extracted}" ] \
    || { rm -rf "${td}"; fail "no prometheus binary found inside '${tb}'"; }
  install -m 0755 "${extracted}" "${BIN}"
  rm -rf "${td}"
}

current_version="$( "${BIN}" --version 2>&1 | awk '/prometheus,? version/{for(i=1;i<=NF;i++) if($i=="version") {print $(i+1); exit}}' 2>/dev/null || true )"

if [ -n "${PROMETHEUS_BINARY}" ]; then
  # (a) explicit pre-staged binary.
  [ -f "${PROMETHEUS_BINARY}" ] || fail "--PROMETHEUS_BINARY '${PROMETHEUS_BINARY}' is not a file"
  "${PROMETHEUS_BINARY}" --version >/dev/null 2>&1 \
    || fail "--PROMETHEUS_BINARY '${PROMETHEUS_BINARY}' does not run as a prometheus binary (wrong arch?)"
  install -m 0755 "${PROMETHEUS_BINARY}" "${BIN}"
  say "using pre-staged prometheus binary ${PROMETHEUS_BINARY} -> ${BIN}"
elif [ -n "${PROMETHEUS_TARBALL}" ]; then
  # (b) explicit pre-staged tarball.
  [ -r "${PROMETHEUS_TARBALL}" ] || fail "cannot read --PROMETHEUS_TARBALL '${PROMETHEUS_TARBALL}'"
  say "extracting pre-staged tarball ${PROMETHEUS_TARBALL} ..."
  install_from_tarball "${PROMETHEUS_TARBALL}"
  say "installed prometheus from ${PROMETHEUS_TARBALL} -> ${BIN}"
elif [ -x "${BIN}" ] && [ "${current_version}" = "${PROMETHEUS_VERSION}" ]; then
  # (c) right version already on disk.
  say "prometheus ${PROMETHEUS_VERSION} already present at ${BIN}."
else
  # (d) download.
  tarball="prometheus-${PROMETHEUS_VERSION}.${os}-${arch}.tar.gz"
  url="${PROMETHEUS_DOWNLOAD_BASE}/v${PROMETHEUS_VERSION}/${tarball}"
  say "downloading ${url} ..."
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  if ! curl -fL --retry 3 --connect-timeout 10 -o "${tmpdir}/${tarball}" "${url}"; then
    fail "failed to download prometheus from ${url} — check network, set a mirror with --PROMETHEUS_DOWNLOAD_BASE, or stage the binary with --PROMETHEUS_BINARY / --PROMETHEUS_TARBALL."
  fi
  say "extracting ..."
  install_from_tarball "${tmpdir}/${tarball}"
  trap - EXIT
  rm -rf "${tmpdir}"
  say "installed prometheus ${PROMETHEUS_VERSION} -> ${BIN}"
fi

# 8. Warn if remote_write target is loopback.
case "${REMOTE_WRITE_URL}" in
  *://127.0.0.1:*|*://127.0.0.1/*|*://localhost:*|*://localhost/*)
    warn "remote_write target is loopback (${REMOTE_WRITE_URL}) — this only works if the central Prometheus is on this same login node."
    ;;
esac

# 9. Materialize prometheus.yml.
say "writing config to ${CONFIG_FILE} (cluster=${CLUSTER_LABEL}, remote_write=${REMOTE_WRITE_URL}) ..."

static_configs_body=""
for i in "${!LABELS[@]}"; do
  static_configs_body+="      - targets: [\"${ENDPOINTS[$i]}\"]"$'\n'
  static_configs_body+="        labels:"$'\n'
  static_configs_body+="          instance: ${LABELS[$i]}"$'\n'
done

cat > "${CONFIG_FILE}" <<YAML
global:
  scrape_interval: ${SCRAPE_INTERVAL}
  scrape_timeout: 10s
  external_labels:
    cluster: ${CLUSTER_LABEL}

scrape_configs:
  - job_name: dcgm
    metrics_path: /metrics
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

# 10. Stop the previously-launched agent (if any) before binding the port.
if [ -n "${existing_pid}" ]; then
  stop_agent
fi

# 11. Build a no_proxy list that includes every compute-node host so that an
#     HTTPS_PROXY set in the user's shell environment doesn't intercept scrapes.
no_proxy_existing="${NO_PROXY:-${no_proxy:-}}"
no_proxy_value="localhost,127.0.0.1"
for ep in "${ENDPOINTS[@]}"; do
  no_proxy_value+=",${ep%:*}"
done
# The remote_write push to the central Prometheus should also bypass any
# shell proxy (it is reached directly from this login node).
rw_host="$(url_host "${REMOTE_WRITE_URL}")"
[ -n "${rw_host}" ] && no_proxy_value+=",${rw_host}"
[ -n "${no_proxy_existing}" ] && no_proxy_value="${no_proxy_existing},${no_proxy_value}"

# 12. Launch the agent as a detached background process.
say "starting prometheus-agent on 127.0.0.1:${AGENT_PORT} ..."
# shellcheck disable=SC2086
nohup env \
  no_proxy="${no_proxy_value}" \
  NO_PROXY="${no_proxy_value}" \
  "${BIN}" \
    --config.file="${CONFIG_FILE}" \
    --enable-feature=agent \
    --storage.agent.path="${DATA_DIR}" \
    --web.listen-address="127.0.0.1:${AGENT_PORT}" \
  > "${LOG_FILE}" 2>&1 < /dev/null &
agent_pid_started=$!
echo "${agent_pid_started}" > "${PID_FILE}"
sleep 0.5

if ! kill -0 "${agent_pid_started}" 2>/dev/null; then
  warn "prometheus-agent exited immediately — tail of log:"
  tail -n 30 "${LOG_FILE}" >&2 || true
  fail "agent failed to start; see ${LOG_FILE} for details."
fi
say "prometheus-agent started (pid=${agent_pid_started}, log=${LOG_FILE})."

# 13. Wait for /-/ready.
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
  || warn "prometheus-agent did not become ready after 20s — check ${LOG_FILE}."

# 14. Aggregate scrape-target health.
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

# 15. Confirm at least one batch has flushed successfully.
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
  warn "  tail -f ${LOG_FILE}"
fi

# 16. Drop tiny standalone helper scripts so the user can stop/status the agent
#     even when install.sh was invoked via curl-pipe (no install.sh on disk).
cat > "${INSTALL_DIR}/stop.sh" <<'HELPER'
#!/usr/bin/env bash
set -eu
PID_FILE="$(cd "$(dirname "$0")" && pwd)/prometheus.pid"
if [ ! -f "${PID_FILE}" ]; then
  echo "no PID file at ${PID_FILE} — agent not running."
  exit 0
fi
pid="$(cat "${PID_FILE}")"
if ! kill -0 "${pid}" 2>/dev/null; then
  echo "recorded pid ${pid} is not alive — cleaning up ${PID_FILE}."
  rm -f "${PID_FILE}"
  exit 0
fi
echo "stopping prometheus-agent (pid=${pid}) ..."
kill "${pid}" 2>/dev/null || true
waited=0
while kill -0 "${pid}" 2>/dev/null; do
  sleep 0.5
  waited=$((waited + 1))
  if [ "${waited}" -ge 20 ]; then
    echo "agent did not exit after 10s — sending SIGKILL."
    kill -9 "${pid}" 2>/dev/null || true
    break
  fi
done
rm -f "${PID_FILE}"
echo "stopped."
HELPER
chmod +x "${INSTALL_DIR}/stop.sh"

cat > "${INSTALL_DIR}/status.sh" <<'HELPER'
#!/usr/bin/env bash
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="${DIR}/prometheus.pid"
if [ -f "${PID_FILE}" ]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" 2>/dev/null; then
    echo "prometheus-agent running (pid=${pid})"
    echo "  log:    ${DIR}/prometheus.log"
    echo "  config: ${DIR}/prometheus.yml"
    exit 0
  fi
fi
echo "prometheus-agent is not running"
exit 1
HELPER
chmod +x "${INSTALL_DIR}/status.sh"

# 17. Final banner.
node_list=""
for i in "${!LABELS[@]}"; do
  node_list+="    ${LABELS[$i]} -> ${ENDPOINTS[$i]}"$'\n'
done

cat <<EOF

================================================================
  GPU push gateway for cluster '${CLUSTER_LABEL}' is up.

  Install dir: ${INSTALL_DIR}
  PID file:    ${PID_FILE}  (pid=${agent_pid_started})
  Log file:    ${LOG_FILE}

  Compute nodes scraped:
${node_list}
  Manage:
    ${INSTALL_DIR}/status.sh        # check whether it's running
    ${INSTALL_DIR}/stop.sh          # stop the agent
    tail -f ${LOG_FILE}
    # Re-run install.sh (with --COMPUTE_NODES etc.) to reconfigure + restart.

  Local checks:
    curl http://127.0.0.1:${AGENT_PORT}/-/ready          # agent
    curl http://127.0.0.1:${AGENT_PORT}/api/v1/targets   # per-node health

  Verify in the server Prometheus:
    ${PROMETHEUS_URL}/graph?g0.expr=DCGM_FI_DEV_GPU_UTIL%7Bcluster%3D%22${CLUSTER_LABEL}%22%7D

  Grafana:    ${GRAFANA_URL}
  Prometheus: ${PROMETHEUS_URL}

  Survive reboot (no systemd / no sudo): add a crontab entry, e.g.
    (crontab -l 2>/dev/null; echo "@reboot $0 --COMPUTE_NODES '${COMPUTE_NODES}' --PROMETHEUS_URL '${PROMETHEUS_URL}' --INSTALL_DIR '${INSTALL_DIR}'") | crontab -
================================================================
EOF
