# GPU Fleet Monitor

Push-based GPU monitoring for hosts behind NAT. Each GPU host runs the
official NVIDIA `dcgm-exporter` plus a tiny Prometheus in **agent mode**
that scrapes locally and `remote_write`s samples to the server Prometheus.
Grafana renders the dashboard.

For GPUs you rent on **vast.ai** (where you can't install a host-side
exporter), a separate `vast.ai/` deployment polls the vast.ai REST API
from anywhere and pushes the same way.

```
┌─────────────────────────────────────────┐
│ GPU node (any host, may be behind NAT)  │ ─┐
│  client/install.sh                      │  │
│   - dcgm-exporter        (compose-net)  │  │
│   - prometheus-agent     (scrape + push)│  │ remote_write (push)   ┌────────────────────────┐
└─────────────────────────────────────────┘  ├─────────────────────▶ │ Visualization (shared) │
┌─────────────────────────────────────────┐  │                       │  Prometheus :9090      │
│ Any host (no GPU needed)                │  │                       │  Grafana    :3000      │
│  vast.ai/install.sh                     │  │                       │  server/install.sh     │
│   - vastai-exporter      (polls API)    │  │                       └────────────────────────┘
│   - prometheus-agent     (scrape + push)│ ─┘
└─────────────────────────────────────────┘
```

## Component versions

| Component | Image |
|-----------|-------|
| Prometheus | `prom/prometheus:v2.55.0` |
| Grafana | `grafana/grafana:10.4.2` |
| DCGM Exporter | `nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.1-ubuntu22.04` |
| vast.ai Exporter | `gpu-monitor-vastai-exporter:latest` (built locally, see `vast.ai/`) |

## How it works

The server Prometheus only needs to expose `/api/v1/write` to the GPU
nodes; the GPU host never has to be reachable from the public internet.
Only `DCGM_*` metrics (from `client/`) and `vastai_*` metrics (from
`vast.ai/`) are forwarded — `write_relabel_configs` drops everything
else — keeping bandwidth and storage minimal.

Each `install.sh` is fully self-contained — it materializes its own
`docker-compose.yml`, `prometheus.yml`, and (for the server) Grafana
datasource provisioning under `${INSTALL_DIR}` (default
`$(pwd)/gpu-monitor-server`, `gpu-monitor-client`, or `gpu-monitor-vastai`),
then runs `docker compose up -d`. Re-running regenerates configs and
recreates containers.

## Prerequisites

- Docker with Compose v2 plugin
- (Client only) NVIDIA driver + NVIDIA Container Toolkit
- (vast.ai only) A vast.ai API key — get one at <https://cloud.vast.ai/cli/>

## 1. Bring up the visualization host (Prometheus + Grafana)
```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/server/install.sh)"
```

Brings up Prometheus (with `--web.enable-remote-write-receiver` and
`--web.enable-lifecycle`) and Grafana (with the Prometheus datasource
already provisioned).

| Variable | Default |
|----------|---------|
| `PROMETHEUS_PORT` | `9090` |
| `GRAFANA_PORT` | `3000` |
| `GRAFANA_ADMIN_USER` | `admin` |
| `GRAFANA_ADMIN_PASSWORD` | `admin` |
| `INSTALL_DIR` | `$(pwd)/gpu-monitor-server` |

```bash
GRAFANA_ADMIN_PASSWORD=s3cret \
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/server/install.sh)"
```

## 2. Deploy on each GPU host
```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/client/install.sh)" -- \
  --PROMETHEUS_URL http://<server-host>:9090 \
  --GRAFANA_URL    http://<server-host>:3000
```

For a local end-to-end test where both sides run on the same machine,
use `--PROMETHEUS_URL http://127.0.0.1:9090 --GRAFANA_URL http://127.0.0.1:3000`.
The script rewrites `127.0.0.1`/`localhost` to `host.docker.internal`
inside the agent's `prometheus.yml`, so the container can still reach
the host-bound Prometheus.

| Flag / env var | Default |
|----------------|---------|
| `--PROMETHEUS_URL` | `http://43.133.11.173:9090` |
| `--GRAFANA_URL` | `http://43.133.11.173:3000` |
| `--REMOTE_WRITE_URL` | `<PROMETHEUS_URL>/api/v1/write` |
| `--INSTANCE_LABEL` | `$(hostname)` |
| `--EXPORTER_PORT` | `9400` |
| `--AGENT_PORT` | `9091` |
| `--INSTALL_DIR` | `$(pwd)/gpu-monitor-client` |

Run with `--help` for full usage. CLI flags override same-name
environment variables.

The prometheus-agent web UI binds to `127.0.0.1` only (not exposed
externally). The scrape interval is 15 s and `remote_write` batches
up to 1000 samples per send with a 5 s deadline.

The client script:
1. Verifies Docker, the NVIDIA driver, and the Container Toolkit.
2. Writes `docker-compose.yml` + `prometheus.yml` to `${INSTALL_DIR}`.
3. Probes the server Prometheus for the receiver flag and warns if off.
4. `docker compose up -d`.
5. Waits for `dcgm-exporter:/metrics` and `prometheus-agent:/-/ready`.
6. Confirms at least one successful `remote_write` batch (no failed
   samples).

## 3. Monitor vast.ai rented instances

For GPUs rented on vast.ai you can't deploy `dcgm-exporter` inside the
host, so we ship a separate exporter under `vast.ai/` that polls the
vast.ai REST API from any machine (no GPU required). It exposes
`vastai_*` gauges on `:9401/metrics` and rides the same prometheus-agent
+ `remote_write` path to the server.

### Build the image

```bash
cd vast.ai
./build.sh                                       # → gpu-monitor-vastai-exporter:latest
./build.sh --IMAGE myrepo/vastai-exporter:1.0 --PUSH
./build.sh --PLATFORM linux/amd64,linux/arm64 --PUSH   # multi-arch via buildx
```

### Deploy

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/vast.ai/install.sh)" -- \
  --VAST_API_KEY    <your_vast_ai_api_key> \
  --PROMETHEUS_URL  http://<server-host>:9090 \
  --GRAFANA_URL     http://<server-host>:3000
```

If sources aren't present locally, `install.sh` fetches Dockerfile +
exporter.py + requirements.txt from GitHub raw, builds the image,
then brings up the stack. Pass `--SKIP_BUILD` to use an existing tag
(e.g. one pushed via `build.sh --PUSH`).

| Flag / env var | Default |
|----------------|---------|
| `--VAST_API_KEY` | _required_ (also reads `VAST_API_KEY` / `VASTAI_API_KEY`) |
| `--PROMETHEUS_URL` | `http://43.133.11.173:9090` |
| `--GRAFANA_URL` | `http://43.133.11.173:3000` |
| `--REMOTE_WRITE_URL` | `<PROMETHEUS_URL>/api/v1/write` |
| `--INSTANCE_LABEL` | `vastai-$(hostname)` |
| `--EXPORTER_PORT` | `9401` |
| `--AGENT_PORT` | `9092` |
| `--SCRAPE_INTERVAL` | `30` (seconds; exporter cache TTL between API calls) |
| `--VAST_API_URL` | `https://console.vast.ai/api/v0` |
| `--VASTAI_EXPORTER_IMAGE` | `gpu-monitor-vastai-exporter:latest` |
| `--SOURCE_DIR` | autodetect (script dir → `$(pwd)/vast.ai` → `$(pwd)`) |
| `--GITHUB_RAW` | `https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/vast.ai` |
| `--INSTALL_DIR` | `$(pwd)/gpu-monitor-vastai` |
| `--SKIP_BUILD` | off — when set, use `--VASTAI_EXPORTER_IMAGE` as-is (pull if missing) |
| `--SKIP_USER` | off — set if the API key lacks the `/users/current/` scope |

Run with `--help` for full usage.

### Metrics exposed

Per-instance gauges (label set: `instance_id`, `machine_id`, `gpu_name`,
`num_gpus`, `geolocation`, `label`):

- `vastai_instance_gpu_util_percent`, `vastai_instance_gpu_temp_celsius`
- `vastai_instance_gpu_mem_used_mb`, `vastai_instance_gpu_ram_mb`
- `vastai_instance_cpu_util_percent`, `vastai_instance_cpu_cores`,
  `vastai_instance_mem_used_gb`, `vastai_instance_mem_total_gb`
- `vastai_instance_disk_util_percent`, `vastai_instance_disk_space_gb`
- `vastai_instance_inet_up_mbps`, `vastai_instance_inet_down_mbps`,
  `vastai_instance_inet_up_billed_gb`, `vastai_instance_inet_down_billed_gb`
- `vastai_instance_dph_total_usd`, `vastai_instance_dph_base_usd`,
  `vastai_instance_storage_cost_usd`
- `vastai_instance_dlperf`, `vastai_instance_dlperf_per_dollar`,
  `vastai_instance_reliability`, `vastai_instance_score`
- `vastai_instance_duration_seconds`
- `vastai_instance_status{status="running|loading|exited|..."}` (1/0 per bucket)
- `vastai_instance_info` (constant 1; carries image, hostname labels)

Account & self-monitoring:
- `vastai_user_credit_usd`, `vastai_user_last_billed_usd`
- `vastai_scrape_success{endpoint="instances|user"}`,
  `vastai_scrape_duration_seconds{endpoint=...}`
- `vastai_up` (1 if `/instances/` last poll succeeded)

## Retrofit an existing Prometheus
If the visualization host already runs its own Prometheus and you don't
want `server/install.sh` to replace it, just enable the remote-write
receiver flag on the existing instance:

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/server/enable-remote-write.sh)" -- --apply
```

The script auto-detects the running Prometheus container, patches the
compose file (with backup) or prints the manual `docker run` change,
recreates the container, and verifies the flag is reported.

## Stop / clean up
Each install dir is a normal docker-compose project, so:
```bash
cd ~/gpu-monitor-server      # or gpu-monitor-client, or gpu-monitor-vastai
docker compose down          # stop containers, keep data
docker compose down -v       # also wipe persistent volumes
```
