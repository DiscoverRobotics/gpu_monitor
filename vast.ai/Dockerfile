# vastai-exporter: Prometheus exporter for vast.ai rented GPU instances.
# Build:  docker build -t gpu-monitor-vastai-exporter:latest .
# Run:    docker run --rm -p 9401:9401 -e VASTAI_API_KEY=... gpu-monitor-vastai-exporter:latest
FROM python:3.12-slim

LABEL org.opencontainers.image.title="vastai-exporter" \
      org.opencontainers.image.description="Prometheus exporter for vast.ai instances and account." \
      org.opencontainers.image.source="https://github.com/DiscoverRobotics/gpu_monitor"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install -r /app/requirements.txt

COPY exporter.py /app/exporter.py

# Run as non-root for safety.
RUN useradd --system --no-create-home --uid 65532 vastai \
 && chown -R vastai:vastai /app
USER vastai

EXPOSE 9401

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:9401/health',timeout=3).status==200 else 1)"

ENTRYPOINT ["python", "/app/exporter.py"]
