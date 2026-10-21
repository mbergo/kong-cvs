#!/usr/bin/env bash
# Step 03: run Grafana Alloy to ship Kong metrics to Grafana Cloud.
# Idempotent: replaces an existing container with the same name.
set -euo pipefail
cd "$(dirname "$0")/.."
source config.env
[ -r secrets/grafana.env ] || { echo "missing secrets/grafana.env" >&2; exit 1; }

docker rm -f "$GRAFANA_ALLOY_CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d --name "$GRAFANA_ALLOY_CONTAINER_NAME" --restart unless-stopped \
  --network host \
  --env-file secrets/grafana.env \
  -e "KONG_STATUS_PORT=$KONG_STATUS_PORT" \
  -v "$PWD/alloy/config.alloy:/etc/alloy/config.alloy:ro" \
  "$GRAFANA_ALLOY_IMAGE" \
  run /etc/alloy/config.alloy --server.http.listen-addr=127.0.0.1:12345 --storage.path=/var/lib/alloy/data

echo "waiting for first remote_write..."
sleep 20
docker logs "$GRAFANA_ALLOY_CONTAINER_NAME" 2>&1 | grep -iE 'error|401|403' | tail -5 || true
echo "alloy UI: http://127.0.0.1:12345 (check prometheus.remote_write.grafana_cloud health)"
