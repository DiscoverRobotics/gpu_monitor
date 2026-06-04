# GPU Fleet Monitor

Push-based GPU monitoring for hosts behind NAT. Each GPU host runs the
official NVIDIA `dcgm-exporter` plus a tiny Prometheus in **agent mode**
that scrapes locally and `remote_write`s samples to the server Prometheus.
Grafana renders the dashboard.

```
┌─────────────────────────────────────────┐                       ┌────────────────────────┐
│ GPU node (any host, may be behind NAT)  │   remote_write (push) │ Visualization (shared) │
│  client/install.sh                      │ ────────────────────▶ │  Prometheus :9090      │
│   - dcgm-exporter        (compose-net)  │                       │  Grafana    :3000      │
│   - prometheus-agent     (scrape + push)│                       │  server/install.sh     │
└─────────────────────────────────────────┘                       └────────────────────────┘
```

## Component versions

| Component | Image |
|-----------|-------|
| Prometheus | `prom/prometheus:v2.55.0` |
| Grafana | `grafana/grafana:10.4.2` |
| DCGM Exporter | `nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.1-ubuntu22.04` |

## How it works

The server Prometheus only needs to expose `/api/v1/write` to the GPU
nodes; the GPU host never has to be reachable from the public internet.
Only `DCGM_*` metrics are forwarded (via `write_relabel_configs`), keeping
bandwidth and storage minimal.

Each `install.sh` is fully self-contained — it materializes its own
`docker-compose.yml`, `prometheus.yml`, and (for the server) Grafana
datasource provisioning under `${INSTALL_DIR}` (default
`$(pwd)/gpu-monitor-server` or `$(pwd)/gpu-monitor-client`), then runs
`docker compose up -d`. Re-running regenerates configs and recreates
containers.

## Prerequisites

- Docker with Compose v2 plugin
- (Client only) NVIDIA driver + NVIDIA Container Toolkit

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

## 3. Deploy on the login node when compute nodes are air-gapped
When the compute nodes can't reach the central Prometheus directly
(typical HPC layout: login node ↔ external network ↔ compute nodes that
only see the internal network), run `dcgm-exporter` manually on each
compute node and then deploy a single gateway agent on the login node.
The gateway scrapes every compute node's `:9400/metrics` and
`remote_write`s the samples to the central Prometheus.

```
┌─────────────────┐      ┌──────────────────────┐                         ┌────────────────────────┐
│ compute01:9400  │◀─┐   │ Login node           │   remote_write (push)   │ Visualization (shared) │
│ compute02:9400  │◀─┼───│ client-gateway/      │ ──────────────────────▶ │  Prometheus :9090      │
│ compute03:9400  │◀─┘   │  install.sh          │                         │  Grafana    :3000      │
│ (dcgm-exporter) │      │  - prometheus-agent  │                         │  server/install.sh     │
└─────────────────┘      └──────────────────────┘                         └────────────────────────┘
   internal network          login node has both
   only                      networks
```

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/client-gateway/install.sh)" -- \
  --PROMETHEUS_URL http://<server-host>:9090 \
  --GRAFANA_URL    http://<server-host>:3000 \
  --COMPUTE_NODES  compute01,compute02,compute03
```

Each entry in `--COMPUTE_NODES` is `[label=]host[:port]`. The hostname is
the default `instance` label and `--EXPORTER_PORT` (default `9400`) the
default port. Use the explicit `label=` form when scraping by IP or when
you want a friendlier instance name:

```bash
--COMPUTE_NODES gpu1=10.0.0.11,gpu2=10.0.0.12:9400,gpu3=10.0.0.13
```

For larger clusters, pass `--COMPUTE_NODES_FILE /path/to/nodes.txt`
(one entry per line, `#` comments and blank lines ignored).

| Flag / env var | Default |
|----------------|---------|
| `--PROMETHEUS_URL` | `http://43.133.11.173:9090` |
| `--GRAFANA_URL` | `http://43.133.11.173:3000` |
| `--REMOTE_WRITE_URL` | `<PROMETHEUS_URL>/api/v1/write` |
| `--COMPUTE_NODES` | *(required)* |
| `--COMPUTE_NODES_FILE` | *(none)* |
| `--CLUSTER_LABEL` | `$(hostname)` — attached as `external_labels.cluster` |
| `--SCRAPE_INTERVAL` | `15s` |
| `--EXPORTER_PORT` | `9400` |
| `--AGENT_PORT` | `9091` |
| `--INSTALL_DIR` | `$(pwd)/gpu-monitor-gateway` |
| `--ALLOW_NO_NODES` | *(off)* — continue when 0 compute nodes respond at pre-flight |

The gateway agent runs in `network_mode: host` so it can resolve the
compute-node hostnames via the login node's `/etc/hosts` / DNS and reach
them on the internal network with no `extra_hosts` plumbing. The agent
UI is still bound to `127.0.0.1:${AGENT_PORT}` only.

The gateway script:
1. Verifies Docker (no NVIDIA driver needed — no GPU on the login node).
2. Parses + validates the node list; rejects duplicate `instance` labels.
3. Probes each compute node's `/metrics`; warns per unreachable node and
   fails on zero reachable unless `--ALLOW_NO_NODES`.
4. Probes the server Prometheus for the receiver flag.
5. Confirms `--AGENT_PORT` is free on the login node.
6. Writes `docker-compose.yml` + `prometheus.yml` to `${INSTALL_DIR}`.
7. `docker compose up -d`, waits for `/-/ready`, reports per-node
   target health, and confirms at least one successful `remote_write`
   batch.

Each series is tagged with the per-node `instance` label and the
`cluster=${CLUSTER_LABEL}` external label, so dashboards can filter by
both the cluster and the individual compute node:

```promql
DCGM_FI_DEV_GPU_UTIL{cluster="<login-hostname>", instance="compute01"}
```

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
The install dir is a normal docker-compose project, so:
```bash
cd ~/gpu-monitor-server      # or gpu-monitor-client, or gpu-monitor-gateway
docker compose down          # stop containers, keep data
docker compose down -v       # also wipe persistent volumes
```
