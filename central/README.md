# Central visualization stack — Prometheus + Grafana

One-click bring-up of the visualization side of the GPU fleet monitor.
Prometheus accepts `remote_write` from GPU nodes; Grafana renders the
data and is preconfigured with the Prometheus datasource.

```bash
cd gpu_monitor/central
./deploy.sh
```

The script:
1. Verifies Docker + Compose v2 are available.
2. `docker compose up -d` (Prometheus with `--web.enable-remote-write-receiver`, Grafana 10.4 with the datasource auto-provisioned).
3. Waits for `prometheus /-/ready` and `grafana /api/health`.
4. Confirms the remote-write receiver flag is reported by the API.

Endpoints (defaults):
- Prometheus: <http://localhost:9090> — write at `/api/v1/write`
- Grafana:    <http://localhost:3000> — login `admin` / `admin`

## Variables
| Variable                  | Default | Meaning                                        |
|---------------------------|---------|------------------------------------------------|
| `PROMETHEUS_PORT`         | `9090`  | Host port for Prometheus.                      |
| `GRAFANA_PORT`            | `3000`  | Host port for Grafana.                         |
| `GRAFANA_ADMIN_USER`      | `admin` | Grafana initial admin login.                   |
| `GRAFANA_ADMIN_PASSWORD`  | `admin` | Grafana initial admin password.                |

Override at deploy time, e.g.:
```bash
GRAFANA_ADMIN_PASSWORD=s3cret ./deploy.sh
```

## Files
| File                                              | Purpose                                                                    |
|---------------------------------------------------|----------------------------------------------------------------------------|
| `docker-compose.yml`                              | Prometheus + Grafana services with persistent volumes.                     |
| `prometheus.yml`                                  | Central Prometheus config — only scrapes itself; data arrives via push.    |
| `grafana/provisioning/datasources/prometheus.yml` | Auto-provisions the in-network Prometheus datasource for Grafana.          |
| `deploy.sh`                                       | Bring-up + health checks.                                                  |
| `enable-remote-write.sh`                          | Retrofit an *already-running* Prometheus that lacks the receiver flag.     |

## When to use `enable-remote-write.sh`
Use it when the host already has its own Prometheus deployment that
predates this stack and you don't want to replace it — the script
patches the receiver flag onto the existing container/compose. For a
fresh install, `./deploy.sh` already starts Prometheus with the flag
enabled, so you don't need it.

## Stop / clean up
```bash
docker compose down            # stop containers, keep data
docker compose down -v         # also wipe Prometheus + Grafana data
```
