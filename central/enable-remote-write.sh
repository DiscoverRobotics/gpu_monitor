#!/usr/bin/env bash
# Enable --web.enable-remote-write-receiver on the central Prometheus.
#
# Run this on 143.198.139.25 after `ssh`-ing in. It detects how Prometheus
# is deployed (docker-compose / docker run / systemd), proposes the change,
# and applies it only after you confirm (or pass --apply).
#
# Re-running is a no-op once the flag is on.
set -euo pipefail

PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
FLAG="--web.enable-remote-write-receiver"
APPLY=0

for arg in "$@"; do
  case "$arg" in
    --apply|-y) APPLY=1 ;;
    -h|--help)
      sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m[remote-write]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[remote-write]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[remote-write]\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  [ "$APPLY" = 1 ] && return 0
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# 1. Reach Prometheus.
say "probing ${PROMETHEUS_URL} ..."
flags_json="$(curl -fsS --max-time 5 "${PROMETHEUS_URL}/api/v1/status/flags" 2>/dev/null || true)"
[ -z "${flags_json}" ] && fail "cannot reach ${PROMETHEUS_URL} — is Prometheus running on this host?"

if echo "${flags_json}" | grep -q '"web.enable-remote-write-receiver":"true"'; then
  say "remote-write-receiver is already enabled. Nothing to do."
  exit 0
fi
say "remote-write-receiver is currently disabled."

# 2. Detect deployment.
command -v docker >/dev/null 2>&1 || fail "docker not on PATH; only the docker path is automated. See manual section below."

container="$(docker ps --format '{{.Names}} {{.Image}}' \
              | awk '$2 ~ /(^|\/)prom\/prometheus(:|$)|(^|\/)prometheus(:|$)/ {print $1; exit}')"

if [ -z "${container}" ]; then
  cat >&2 <<EOF
Could not auto-detect a running Prometheus container. Apply manually:

  Docker run:
    docker stop <name> && docker rm <name>
    docker run -d --name <name> ... <image> \\
      --config.file=/etc/prometheus/prometheus.yml \\
      ${FLAG}

  Docker compose:
    Add '${FLAG}' under the prometheus service's 'command:' list, then:
    docker compose up -d prometheus

  Systemd:
    Edit ExecStart in the unit file (see 'systemctl cat prometheus'),
    append '${FLAG}', then:
    sudo systemctl daemon-reload && sudo systemctl restart prometheus
EOF
  exit 1
fi

say "detected container: ${container}"

# 3. Prefer the docker-compose path if we can find the project.
project="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "${container}" 2>/dev/null || true)"
service="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.service" }}' "${container}" 2>/dev/null || true)"
config_file="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "${container}" 2>/dev/null || true)"
# config_files may be a comma-separated list; take the first existing path.
compose_file=""
IFS=',' read -ra _cfs <<<"${config_file}"
for cf in "${_cfs[@]}"; do
  [ -f "${cf}" ] && { compose_file="${cf}"; break; }
done

if [ -n "${project}" ] && [ -n "${service}" ] && [ -n "${compose_file}" ]; then
  say "compose project: ${project} (service: ${service}, file: ${compose_file})"

  if grep -qF -- "${FLAG}" "${compose_file}"; then
    say "${FLAG} already present in ${compose_file}. Will just recreate the container."
  else
    backup="${compose_file}.bak.$(date +%s)"
    say "will append '${FLAG}' to the ${service} service's command list."
    say "backup: ${backup}"
    confirm "Edit ${compose_file} now?" || fail "aborted by user."
    cp "${compose_file}" "${backup}"

    python3 - "$compose_file" "$service" "$FLAG" <<'PY'
import sys, re, pathlib
path, service, flag = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(path).read_text()
lines = text.splitlines(keepends=True)
out = []
i = 0
in_service = False
service_indent = None
patched = False

def line_indent(s):
    return len(s) - len(s.lstrip(' '))

while i < len(lines):
    line = lines[i]
    stripped = line.lstrip(' ')
    if not patched and not in_service and re.match(r'^\s*' + re.escape(service) + r':\s*$', line):
        in_service = True
        service_indent = line_indent(line)
        out.append(line); i += 1; continue
    if in_service:
        if stripped.strip() and line_indent(line) <= service_indent and not stripped.startswith('#'):
            # Left the service block without finding command:
            raise SystemExit(f"ERROR: did not find a 'command:' list under service '{service}' in {path}; edit by hand.")
        m = re.match(r'^(\s+)command:\s*$', line)
        if m:
            cmd_indent = len(m.group(1))
            out.append(line); i += 1
            # collect existing command list items
            item_indent = None
            while i < len(lines):
                l = lines[i]
                ls = l.lstrip(' ')
                if ls.startswith('- '):
                    if item_indent is None:
                        item_indent = line_indent(l)
                    out.append(l); i += 1; continue
                if l.strip() == '' or ls.startswith('#'):
                    out.append(l); i += 1; continue
                break
            indent_str = ' ' * (item_indent if item_indent is not None else cmd_indent + 2)
            out.append(f"{indent_str}- {flag}\n")
            patched = True
            in_service = False
            continue
    out.append(line); i += 1

if not patched:
    raise SystemExit(f"ERROR: could not patch {path} — service '{service}' or its 'command:' list was not found.")

pathlib.Path(path).write_text(''.join(out))
print(f"patched {path}")
PY

    say "compose file patched."
  fi

  confirm "Recreate ${service} via 'docker compose up -d'?" || fail "aborted by user."
  ( cd "$(dirname "${compose_file}")" && docker compose up -d "${service}" )
else
  # Plain `docker run` path — recreate the container with the extra arg.
  say "container is not managed by docker-compose; will recreate it with '${FLAG}' appended."
  current_cmd_json="$(docker inspect --format '{{json .Config.Cmd}}' "${container}")"
  current_args_json="$(docker inspect --format '{{json .Args}}' "${container}")"
  image="$(docker inspect --format '{{.Config.Image}}' "${container}")"
  say "current image: ${image}"
  say "current Cmd:   ${current_cmd_json}"
  say "current Args:  ${current_args_json}"

  cat <<EOF
Automated recreation of a hand-rolled 'docker run' is risky — it would have
to reproduce every flag (volumes, network, env, restart policy) and one
mistake wipes out your dashboards' data source.

Recommended manual step:

  docker stop ${container}
  docker rm ${container}
  # Re-run your original 'docker run ...' command, but append '${FLAG}'
  # after the image name (or to the Prometheus arg list).

If you have a known recreate command in your shell history, run that with
the flag appended.
EOF
  exit 1
fi

# 4. Verify.
say "waiting for Prometheus to come back up ..."
for i in {1..30}; do
  if curl -fsS --max-time 3 "${PROMETHEUS_URL}/-/ready" -o /dev/null 2>&1; then
    break
  fi
  sleep 1
done

flags_json="$(curl -fsS --max-time 5 "${PROMETHEUS_URL}/api/v1/status/flags" 2>/dev/null || true)"
if echo "${flags_json}" | grep -q '"web.enable-remote-write-receiver":"true"'; then
  say "done. ${FLAG} is enabled."
  say "Endpoint: ${PROMETHEUS_URL}/api/v1/write"
else
  fail "Prometheus came back but the flag still isn't reported. Inspect the container logs."
fi
