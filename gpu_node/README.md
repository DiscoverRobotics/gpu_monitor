# GPU node — dcgm-exporter + Prometheus agent (push to central)

Two containers run side-by-side on each GPU host:

| Container                       | Image                                                | Role                                                   |
|---------------------------------|------------------------------------------------------|--------------------------------------------------------|
| `gpu-monitor-dcgm-exporter`     | `nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.1-...`   | Expose GPU metrics on `:9400/metrics` (compose net).   |
| `gpu-monitor-prometheus-agent`  | `prom/prometheus:v2.55.0` (`--enable-feature=agent`) | Scrape dcgm-exporter, `remote_write` to the central.   |

Because the agent does the pushing, this host does **not** need a public IP
or any inbound port from the internet. The exporter is still bound to
`:9400` on the host for local debugging (`curl 127.0.0.1:9400/metrics`).

## Prerequisites
- Docker (>= 20.10) with Compose v2.
- NVIDIA driver (`nvidia-smi` works on the host).
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)
  configured (`docker info` shows `nvidia` under Runtimes).
- The central Prometheus must have `--web.enable-remote-write-receiver` on
  (run `gpu_monitor/central/enable-remote-write.sh` on it once).

## One-click deploy
```bash
# Point at a remote central stack:
./deploy.sh \
  --PROMETHEUS_URL http://<central-host>:9090 \
  --GRAFANA_URL    http://<central-host>:3000

# Or, if both ends run on this machine (local end-to-end test):
./deploy.sh \
  --PROMETHEUS_URL http://127.0.0.1:9090 \
  --GRAFANA_URL    http://127.0.0.1:3000
```

`./deploy.sh --help` lists all flags. Environment variables of the same
name still work as fallbacks; CLI flags take precedence. When the URL
host is `127.0.0.1` or `localhost`, the script rewrites it to
`host.docker.internal` for the agent's `prometheus.yml` so the container
can reach a Prometheus running on the host.

The script:
1. Verifies Docker, the NVIDIA driver, and the Container Toolkit.
2. Renders `prometheus.yml` from `prometheus.yml.tmpl` (substituting
   `INSTANCE_LABEL` and `REMOTE_WRITE_URL`).
3. Probes the central Prometheus for the receiver flag and warns if off.
4. `docker compose up -d`.
5. Waits for `dcgm-exporter:/metrics` and `prometheus-agent:/-/ready`.
6. Confirms at least one successful `remote_write` batch via the agent's
   own `/metrics` (`prometheus_remote_storage_samples_total`).

## Flags / variables
Each option below is available as a CLI flag (e.g. `--PROMETHEUS_URL`)
and as an environment variable of the same name. CLI flags win.

| Name                | Default                                | Meaning                                                         |
|---------------------|----------------------------------------|-----------------------------------------------------------------|
| `--INSTANCE_LABEL`  | `$(hostname)`                          | Label attached to every series this host pushes.                |
| `--PROMETHEUS_URL`  | `http://143.198.139.25:9090`           | Central Prometheus base URL; also used to probe receiver flag.  |
| `--GRAFANA_URL`     | `http://143.198.139.25:3000`           | Printed in the success banner.                                  |
| `--REMOTE_WRITE_URL`| `<PROMETHEUS_URL>/api/v1/write`        | Override the push endpoint if it differs from the base URL.     |
| `--EXPORTER_PORT`   | `9400`                                 | Host port for `dcgm-exporter` (local debugging only).           |
| `--AGENT_PORT`      | `9091`                                 | Host port for the agent's UI/`/metrics` (bound to `127.0.0.1`). |

Examples:
```bash
./deploy.sh --PROMETHEUS_URL http://10.0.0.42:9090 --GRAFANA_URL http://10.0.0.42:3000
./deploy.sh --INSTANCE_LABEL gpu-rig-01 --PROMETHEUS_URL http://central:9090
INSTANCE_LABEL=gpu-rig-01 ./deploy.sh   # env var fallback still works
```

## What is exported
Standard DCGM gauges per GPU, including:
- `DCGM_FI_DEV_GPU_UTIL` — compute utilization (%)
- `DCGM_FI_DEV_MEM_COPY_UTIL` — memory bandwidth utilization (%)
- `DCGM_FI_DEV_FB_USED` / `DCGM_FI_DEV_FB_FREE` — framebuffer memory (MiB)
- `DCGM_FI_DEV_GPU_TEMP` — GPU die temperature (°C)
- `DCGM_FI_DEV_POWER_USAGE` — current power draw (W)
- `DCGM_FI_DEV_SM_CLOCK`, `DCGM_FI_DEV_MEM_CLOCK` — clocks (MHz)

Every series carries `gpu`, `UUID`, `device`, `modelName`, `Hostname`, plus
the `instance` label set to `INSTANCE_LABEL`. A `write_relabel_config` in
`prometheus.yml.tmpl` keeps only `DCGM_*` series, so noise from the agent's
internal metrics never reaches the central TSDB.

## Sanity checks after deploy
```bash
# Locally:
curl -s http://127.0.0.1:9400/metrics | head           # dcgm raw
curl -s http://127.0.0.1:9091/-/ready                  # agent ready
docker logs --tail=50 gpu-monitor-prometheus-agent     # push log

# On the central Prometheus:
curl 'http://143.198.139.25:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL{instance="<your-INSTANCE_LABEL>"}'
```

## Troubleshooting
- **Receiver disabled**: agent logs `server returned HTTP status 404 Not Found`.
  Run `gpu_monitor/central/enable-remote-write.sh` on the central host.
- **`nvidia-container-cli: requirement error`**: Container Toolkit is not
  installed/configured. Run
  `sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker`.
- **Agent shows samples_failed_total > 0**: check the agent logs
  (`docker logs gpu-monitor-prometheus-agent`) — usually a network issue or
  receiver not enabled.
- **Series visible in Prometheus but not Grafana**: Grafana datasource may
  filter by job/instance — confirm the dashboard variables match your
  `INSTANCE_LABEL`.
