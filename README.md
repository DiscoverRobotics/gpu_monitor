# GPU Fleet Monitor

Push-based GPU monitoring for hosts behind NAT. Each GPU host runs the
official NVIDIA `dcgm-exporter` plus a tiny Prometheus in **agent mode**
that scrapes locally and `remote_write`s samples to the central Prometheus.
Grafana renders the dashboard.

```
┌─────────────────────────────────────────┐                       ┌────────────────────────┐
│ GPU node (any host, may be behind NAT)  │   remote_write (push) │ Visualization (shared) │
│  ./gpu_node                             │ ────────────────────▶ │  Prometheus :9090      │
│   - dcgm-exporter        (compose-net)  │                       │  Grafana    :3000      │
│   - prometheus-agent     (scrape + push)│                       └────────────────────────┘
└─────────────────────────────────────────┘
```

The central Prometheus only needs to expose `/api/v1/write` to the GPU
nodes; the GPU host never has to be reachable from the public internet.

## 1. Bring up the visualization host (Prometheus + Grafana)
```bash
cd gpu_monitor/central
./deploy.sh
```

This brings up Prometheus (with `--web.enable-remote-write-receiver`)
and Grafana (with the Prometheus datasource already provisioned). See
`central/README.md` for ports, credentials, and how to retrofit an
existing Prometheus with `enable-remote-write.sh`.

## 2. Deploy on each GPU host
```bash
cd gpu_monitor/gpu_node
./deploy.sh \
  --PROMETHEUS_URL http://<central-host>:9090 \
  --GRAFANA_URL    http://<central-host>:3000
```

For a local end-to-end test where both sides run on the same machine,
use `--PROMETHEUS_URL http://127.0.0.1:9090 --GRAFANA_URL http://127.0.0.1:3000`.
The script rewrites `127.0.0.1`/`localhost` to `host.docker.internal`
inside the agent's `prometheus.yml`, so the container can still reach
the host-bound Prometheus.

The script renders `prometheus.yml` from the template, brings up
`dcgm-exporter` + `prometheus-agent`, smoke-tests the local endpoints,
checks that the central receiver is enabled, and confirms at least one
batch of samples was delivered.

See `gpu_node/README.md` for all flags and troubleshooting.
