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
│   - prometheus-agent     (scrape + push)│                       └────────────────────────┘
└─────────────────────────────────────────┘
```

The server Prometheus only needs to expose `/api/v1/write` to the GPU
nodes; the GPU host never has to be reachable from the public internet.

Each `install.sh` is fully self-contained — it materializes its own
`docker-compose.yml`, `prometheus.yml`, and (for the server) Grafana
datasource provisioning under `${INSTALL_DIR}` (default
`$(pwd)/gpu-monitor-server` or `$(pwd)/gpu-monitor-client`), then runs
`docker compose up -d`. Re-running regenerates configs and recreates
containers.

## 1. Bring up the visualization host (Prometheus + Grafana)
```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/DiscoverRobotics/gpu_monitor/main/server/install.sh)"
```

Brings up Prometheus (with `--web.enable-remote-write-receiver`) and
Grafana (with the Prometheus datasource already provisioned).

Optional environment overrides: `PROMETHEUS_PORT`, `GRAFANA_PORT`,
`GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`, `INSTALL_DIR`.

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

Flags / env vars: `--PROMETHEUS_URL`, `--GRAFANA_URL`,
`--REMOTE_WRITE_URL`, `--INSTANCE_LABEL`, `--EXPORTER_PORT`,
`--AGENT_PORT`, `--INSTALL_DIR`. Run with `--help` for defaults.

The client script:
1. Verifies Docker, the NVIDIA driver, and the Container Toolkit.
2. Writes `docker-compose.yml` + `prometheus.yml` to `${INSTALL_DIR}`.
3. Probes the server Prometheus for the receiver flag and warns if off.
4. `docker compose up -d`.
5. Waits for `dcgm-exporter:/metrics` and `prometheus-agent:/-/ready`.
6. Confirms at least one successful `remote_write` batch.

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
cd ~/gpu-monitor-server      # or gpu-monitor-client
docker compose down          # stop containers, keep data
docker compose down -v       # also wipe persistent volumes
```
