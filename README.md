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

- **Server** (section 1) and **per-host client** (section 2): Docker with
  Compose v2 plugin; the client also needs NVIDIA driver + NVIDIA Container
  Toolkit.
- **Login-node gateway** (section 3): only `curl`, `tar`, `awk` — no docker,
  no sudo, no systemd. The Prometheus binary is downloaded into
  `${INSTALL_DIR}` and run as a `nohup` background process.

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

This deployment is **pure-userland**: no docker, no docker-compose, no
sudo, no systemd units. The script downloads the official Prometheus
release tarball into `${INSTALL_DIR}` and runs it as a `nohup`
background process tracked by a PID file.

```
┌─────────────────┐      ┌──────────────────────┐                         ┌────────────────────────┐
│ compute01:9400  │◀─┐   │ Login node           │   remote_write (push)   │ Visualization (shared) │
│ compute02:9400  │◀─┼───│ client-gateway/      │ ──────────────────────▶ │  Prometheus :9090      │
│ compute03:9400  │◀─┘   │  install.sh          │                         │  Grafana    :3000      │
│ (dcgm-exporter) │      │  prometheus agent    │                         │  server/install.sh     │
│                 │      │  (nohup, no docker)  │                         │                        │
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
default port. Compute nodes are commonly addressed by IP — pass them
directly, with or without the port:

```bash
--COMPUTE_NODES 214.30.239.40:9400,214.30.239.42:9400
```

Use the explicit `label=` form when you want a friendlier instance name
than the bare IP:

```bash
--COMPUTE_NODES gpu1=10.0.0.11,gpu2=10.0.0.12:9400,gpu3=10.0.0.13
```

The login node is the only host with outbound access, so by default the
script downloads the Prometheus release from GitHub there. If that download
is blocked, either point at a mirror with `--PROMETHEUS_DOWNLOAD_BASE`, or
pre-stage the binary you already have and skip the download entirely:

```bash
# reuse a prometheus binary you copied onto the login node
... --PROMETHEUS_BINARY  /home/me/prometheus
# or extract a release tarball you copied over
... --PROMETHEUS_TARBALL /home/me/prometheus-2.55.0.linux-amd64.tar.gz
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
| `--PROMETHEUS_VERSION` | `2.55.0` |
| `--PROMETHEUS_BINARY` | *(none)* — use a pre-staged binary instead of downloading |
| `--PROMETHEUS_TARBALL` | *(none)* — extract a pre-staged release tarball instead of downloading |
| `--PROMETHEUS_DOWNLOAD_BASE` | `https://github.com/prometheus/prometheus/releases/download` |
| `--ALLOW_NO_NODES` | *(off)* — continue when 0 compute nodes respond at pre-flight |

The agent UI is bound to `127.0.0.1:${AGENT_PORT}` only. `no_proxy` is
populated with every compute-node host at start time so a shell
`HTTPS_PROXY` doesn't accidentally intercept the scrapes.

**Manage the running agent:**

`install.sh` writes two tiny standalone helpers next to the binary, so
you don't need the install script on disk to control the agent:

```bash
${INSTALL_DIR}/status.sh        # is it running? pid? log path?
${INSTALL_DIR}/stop.sh          # graceful stop, then SIGKILL after 10s
tail -f ${INSTALL_DIR}/prometheus.log
# To reconfigure + restart: re-run install.sh with new --COMPUTE_NODES etc.
```

If you have install.sh saved locally, `install.sh --STATUS` / `--STOP`
work too.

The gateway script:
1. Sanity-checks `curl`, `tar`, `awk` (no other runtime deps — no docker,
   no NVIDIA driver, no root).
2. Parses + validates the node list; rejects duplicate `instance` labels.
3. Probes each compute node's `/metrics`; warns per unreachable node and
   fails on zero reachable unless `--ALLOW_NO_NODES`.
4. Probes the server Prometheus for the receiver flag.
5. Confirms `--AGENT_PORT` is free on the login node.
6. Resolves the prometheus binary — a `--PROMETHEUS_BINARY` /
   `--PROMETHEUS_TARBALL` you staged, else an already-present matching
   version, else downloads `prometheus-${PROMETHEUS_VERSION}`; writes
   `prometheus.yml` next to it.
7. Stops any previously-launched agent (via the PID file), then
   `nohup`-launches the new one, waits for `/-/ready`, reports per-node
   target health, and confirms at least one successful `remote_write`
   batch.

Each series is tagged with the per-node `instance` label and the
`cluster=${CLUSTER_LABEL}` external label, so dashboards can filter by
both the cluster and the individual compute node:

```promql
DCGM_FI_DEV_GPU_UTIL{cluster="<login-hostname>", instance="compute01"}
```

**Survive reboot without sudo/systemd:**

```bash
(crontab -l 2>/dev/null; \
 echo "@reboot ${INSTALL_DIR}/install.sh --COMPUTE_NODES 'compute01,compute02,compute03' --PROMETHEUS_URL 'http://<server-host>:9090' --INSTALL_DIR '${INSTALL_DIR}'" \
) | crontab -
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
