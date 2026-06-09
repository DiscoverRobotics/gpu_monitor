#!/usr/bin/env python3
"""Prometheus exporter for vast.ai rented instances and account state.

Polls the vast.ai REST API (https://console.vast.ai/api/v0) and exposes
gauges on /metrics. Designed to be scraped by a local prometheus-agent
in the same way nvidia/dcgm-exporter is.

Auth: pass --api-key or set VASTAI_API_KEY in the environment. Get a key
from https://cloud.vast.ai/cli/  (Account -> CLI).
"""
from __future__ import annotations

import argparse
import http.server
import logging
import os
import sys
import threading
import time
from typing import Any, Dict, Iterable, List, Optional, Tuple

import requests
from prometheus_client import CollectorRegistry, generate_latest, CONTENT_TYPE_LATEST
from prometheus_client.core import GaugeMetricFamily

log = logging.getLogger("vastai-exporter")

INSTANCE_LABELS = [
    "instance_id",
    "machine_id",
    "gpu_name",
    "num_gpus",
    "geolocation",
    "label",
]

# Known vast.ai instance states. We always emit a 1/0 series for each of these
# (plus the instance's actual state if it isn't in the list), so that when an
# instance leaves a state its series drops to 0 instead of going stale — which
# makes `vastai_instance_status{status="..."} == 1` reliable for alerting.
STATUS_BUCKETS = (
    "running",
    "loading",
    "exited",
    "created",
    "stopped",
    "offline",
)


def _as_float(value: Any, default: float = 0.0) -> float:
    """Best-effort numeric coercion — vast.ai sometimes returns None/strings."""
    if value is None:
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _label_values(inst: Dict[str, Any]) -> List[str]:
    return [
        str(inst.get("id", "")),
        str(inst.get("machine_id", "")),
        str(inst.get("gpu_name", "") or ""),
        str(inst.get("num_gpus", "") or ""),
        str(inst.get("geolocation", "") or ""),
        str(inst.get("label", "") or ""),
    ]


class VastAICollector:
    """Custom collector — fetches once per scrape, with TTL-based caching."""

    # (metric_name, help, instance_field, scale)
    INSTANCE_METRICS: List[Tuple[str, str, str, float]] = [
        ("vastai_instance_gpu_util_percent",     "GPU utilization (percent, 0-100).",          "gpu_util",     1.0),
        ("vastai_instance_gpu_temp_celsius",     "GPU temperature (Celsius).",                  "gpu_temp",     1.0),
        ("vastai_instance_gpu_mem_used_mb",      "GPU memory used (MiB).",                      "mem_usage",    1.0),
        ("vastai_instance_gpu_ram_mb",           "GPU memory per card (MiB).",                  "gpu_ram",      1.0),
        ("vastai_instance_num_gpus",             "Number of GPUs allocated to the instance.",   "num_gpus",     1.0),
        ("vastai_instance_cpu_util_percent",     "CPU utilization (percent, 0-100).",           "cpu_util",     1.0),
        ("vastai_instance_cpu_cores",            "Number of CPU cores allocated.",              "cpu_cores",    1.0),
        ("vastai_instance_mem_used_gb",          "Host RAM used (GiB).",                        "mem_usage_host", 1.0),
        ("vastai_instance_mem_total_gb",         "Host RAM total allocated (GiB).",             "cpu_ram",      1.0 / 1024.0),
        ("vastai_instance_disk_util_percent",    "Disk utilization (percent, 0-100).",          "disk_util",    1.0),
        ("vastai_instance_disk_space_gb",        "Disk space allocated (GiB).",                 "disk_space",   1.0),
        ("vastai_instance_inet_up_mbps",         "Current upstream bandwidth (Mbps).",          "inet_up",      1.0),
        ("vastai_instance_inet_down_mbps",       "Current downstream bandwidth (Mbps).",        "inet_down",    1.0),
        ("vastai_instance_inet_up_billed_gb",    "Cumulative billed upload (GiB).",             "inet_up_billed", 1.0),
        ("vastai_instance_inet_down_billed_gb",  "Cumulative billed download (GiB).",           "inet_down_billed", 1.0),
        ("vastai_instance_dph_total_usd",        "Effective price ($/hour, all-in).",           "dph_total",    1.0),
        ("vastai_instance_dph_base_usd",         "Base price ($/hour, ex-storage/bw).",         "dph_base",     1.0),
        ("vastai_instance_storage_cost_usd",     "Storage cost ($/hour).",                      "storage_cost", 1.0),
        ("vastai_instance_dlperf",               "DL performance score reported by vast.ai.",   "dlperf",       1.0),
        ("vastai_instance_dlperf_per_dollar",    "DL performance per dollar/hour.",             "dlperf_per_dphtotal", 1.0),
        ("vastai_instance_reliability",          "Host reliability (0-1).",                     "reliability2", 1.0),
        ("vastai_instance_score",                "vast.ai composite score.",                    "score",        1.0),
        ("vastai_instance_duration_seconds",     "Uptime since instance start (seconds).",      "duration",     1.0),
    ]

    def __init__(
        self,
        api_key: str,
        api_url: str = "https://console.vast.ai/api/v0",
        cache_ttl: float = 30.0,
        timeout: float = 15.0,
        include_user: bool = True,
    ) -> None:
        self.api_key = api_key
        self.api_url = api_url.rstrip("/")
        self.cache_ttl = max(1.0, cache_ttl)
        self.timeout = timeout
        self.include_user = include_user

        self._lock = threading.Lock()
        self._cache: Dict[str, Any] = {"instances": None, "user": None}
        self._cache_ts: Dict[str, float] = {"instances": 0.0, "user": 0.0}
        self._last_ok: Dict[str, int] = {"instances": 0, "user": 0}
        self._last_duration: Dict[str, float] = {"instances": 0.0, "user": 0.0}

        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {self.api_key}",
                "Accept": "application/json",
                "User-Agent": "vastai-exporter/1.0",
            }
        )

    # ---- fetching --------------------------------------------------------

    def _get(self, path: str) -> Optional[Dict[str, Any]]:
        url = f"{self.api_url}{path}"
        try:
            r = self.session.get(url, timeout=self.timeout)
            r.raise_for_status()
            return r.json()
        except requests.RequestException as e:
            log.warning("GET %s failed: %s", url, e)
            return None
        except ValueError as e:
            log.warning("GET %s returned non-JSON: %s", url, e)
            return None

    def _fetch(self, key: str, path: str) -> Optional[Dict[str, Any]]:
        now = time.time()
        with self._lock:
            cached = self._cache.get(key)
            if cached is not None and (now - self._cache_ts[key]) < self.cache_ttl:
                return cached

        t0 = time.time()
        data = self._get(path)
        elapsed = time.time() - t0

        with self._lock:
            self._last_duration[key] = elapsed
            if data is not None:
                self._cache[key] = data
                self._cache_ts[key] = time.time()
                self._last_ok[key] = 1
            else:
                self._last_ok[key] = 0
            return self._cache.get(key)

    # ---- collection ------------------------------------------------------

    def collect(self) -> Iterable[GaugeMetricFamily]:
        # ---- /instances/ -----------------------------------------------
        inst_data = self._fetch("instances", "/instances/")
        instances: List[Dict[str, Any]] = []
        if isinstance(inst_data, dict):
            instances = inst_data.get("instances") or []

        # status (running/loading/exited/...) — emit per known bucket so
        # Prometheus alerting on status changes is straightforward.
        status_metric = GaugeMetricFamily(
            "vastai_instance_status",
            "Instance status (1 if the instance is in the labelled state).",
            labels=INSTANCE_LABELS + ["status"],
        )
        info_metric = GaugeMetricFamily(
            "vastai_instance_info",
            "Always 1; carries descriptive labels for joins.",
            labels=INSTANCE_LABELS + ["image", "hostname", "status"],
        )

        gauges: Dict[str, GaugeMetricFamily] = {}
        for name, helptext, _field, _scale in self.INSTANCE_METRICS:
            gauges[name] = GaugeMetricFamily(name, helptext, labels=INSTANCE_LABELS)

        for inst in instances:
            labels = _label_values(inst)
            status = str(inst.get("actual_status") or inst.get("cur_state") or "unknown")
            # Emit 1/0 for every known bucket, plus a 1 for the current state
            # even if vast.ai reports something not in STATUS_BUCKETS.
            for bucket in (*STATUS_BUCKETS, *( (status,) if status not in STATUS_BUCKETS else () )):
                status_metric.add_metric(labels + [bucket], 1.0 if bucket == status else 0.0)
            info_metric.add_metric(
                labels + [
                    str(inst.get("image_uuid") or inst.get("image") or ""),
                    str(inst.get("public_ipaddr") or inst.get("hostname") or ""),
                    status,
                ],
                1.0,
            )
            for name, _helptext, field, scale in self.INSTANCE_METRICS:
                gauges[name].add_metric(labels, _as_float(inst.get(field)) * scale)

        yield info_metric
        yield status_metric
        for g in gauges.values():
            yield g

        # ---- /users/current/ -------------------------------------------
        if self.include_user:
            user_data = self._fetch("user", "/users/current/")
            if isinstance(user_data, dict):
                # the endpoint returns the user object directly (no wrapper)
                user = user_data
                user_credit = GaugeMetricFamily(
                    "vastai_user_credit_usd",
                    "Account credit balance (USD).",
                    labels=["user_id", "email"],
                )
                ulabels = [
                    str(user.get("id", "")),
                    str(user.get("email", "") or ""),
                ]
                user_credit.add_metric(ulabels, _as_float(user.get("credit")))
                yield user_credit

                bal = GaugeMetricFamily(
                    "vastai_user_last_billed_usd",
                    "Most recent billed amount (USD) from last invoice, if exposed.",
                    labels=["user_id", "email"],
                )
                bal.add_metric(ulabels, _as_float(user.get("balance")))
                yield bal

        # ---- exporter self-metrics -------------------------------------
        ok = GaugeMetricFamily(
            "vastai_scrape_success",
            "1 if the last poll of the named vast.ai endpoint succeeded.",
            labels=["endpoint"],
        )
        dur = GaugeMetricFamily(
            "vastai_scrape_duration_seconds",
            "Duration of the last poll of the named vast.ai endpoint.",
            labels=["endpoint"],
        )
        # Only report the user endpoint when we actually poll it, otherwise
        # scrape_success{endpoint="user"} would read 0 and look like a failure.
        endpoints = ("instances", "user") if self.include_user else ("instances",)
        for key in endpoints:
            ok.add_metric([key], float(self._last_ok.get(key, 0)))
            dur.add_metric([key], float(self._last_duration.get(key, 0.0)))
        yield ok
        yield dur

        up = GaugeMetricFamily(
            "vastai_up",
            "1 if at least the instances endpoint last poll succeeded.",
            labels=[],
        )
        up.add_metric([], float(self._last_ok.get("instances", 0)))
        yield up


class _Handler(http.server.BaseHTTPRequestHandler):
    registry: CollectorRegistry = None  # set on subclass below

    def log_message(self, fmt, *args):  # quieter default access log
        log.info("%s - %s", self.address_string(), fmt % args)

    def do_GET(self):  # noqa: N802
        if self.path == "/health" or self.path == "/healthz":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"ok\n")
            return
        if self.path.startswith("/metrics"):
            try:
                payload = generate_latest(self.registry)
            except Exception as e:  # pragma: no cover
                log.exception("generate_latest failed: %s", e)
                self.send_response(500)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(
                b"<html><body><h1>vastai-exporter</h1>"
                b"<p><a href='/metrics'>/metrics</a></p>"
                b"<p><a href='/health'>/health</a></p>"
                b"</body></html>"
            )
            return
        self.send_response(404)
        self.end_headers()


class _ThreadingServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="vast.ai Prometheus exporter")
    p.add_argument(
        "--api-key",
        default=os.environ.get("VASTAI_API_KEY", ""),
        help="vast.ai API key (env: VASTAI_API_KEY).",
    )
    p.add_argument(
        "--api-url",
        default=os.environ.get("VASTAI_API_URL", "https://console.vast.ai/api/v0"),
        help="Base URL for the vast.ai API (env: VASTAI_API_URL).",
    )
    p.add_argument(
        "--listen-address",
        default=os.environ.get("VASTAI_LISTEN_ADDRESS", ":9401"),
        help="host:port to bind the /metrics endpoint (env: VASTAI_LISTEN_ADDRESS).",
    )
    p.add_argument(
        "--scrape-interval",
        type=float,
        default=float(os.environ.get("VASTAI_SCRAPE_INTERVAL", "30")),
        help="Seconds to cache results between vast.ai API calls (env: VASTAI_SCRAPE_INTERVAL).",
    )
    p.add_argument(
        "--timeout",
        type=float,
        default=float(os.environ.get("VASTAI_TIMEOUT", "15")),
        help="HTTP timeout for vast.ai API calls (env: VASTAI_TIMEOUT).",
    )
    p.add_argument(
        "--no-user",
        action="store_true",
        default=os.environ.get("VASTAI_NO_USER", "").lower() in ("1", "true", "yes"),
        help="Skip /users/current/ (use if your key lacks account read scope).",
    )
    p.add_argument(
        "--log-level",
        default=os.environ.get("VASTAI_LOG_LEVEL", "INFO"),
        help="Python logging level (env: VASTAI_LOG_LEVEL).",
    )
    return p.parse_args(argv)


def _parse_listen(listen: str) -> Tuple[str, int]:
    if ":" not in listen:
        return ("0.0.0.0", int(listen))
    host, _, port = listen.rpartition(":")
    if not host:
        host = "0.0.0.0"
    return (host, int(port))


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    if not args.api_key:
        log.error("missing --api-key / VASTAI_API_KEY")
        return 2

    registry = CollectorRegistry()
    collector = VastAICollector(
        api_key=args.api_key,
        api_url=args.api_url,
        cache_ttl=args.scrape_interval,
        timeout=args.timeout,
        include_user=not args.no_user,
    )
    registry.register(collector)

    host, port = _parse_listen(args.listen_address)
    handler = type("_BoundHandler", (_Handler,), {"registry": registry})
    server = _ThreadingServer((host, port), handler)
    log.info(
        "listening on %s:%d (api=%s, interval=%ss, user=%s)",
        host, port, args.api_url, args.scrape_interval, not args.no_user,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
