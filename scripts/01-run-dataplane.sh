#!/usr/bin/env bash
# Step 01: start the Kong AI Gateway data plane connected to Konnect.
# Idempotent: replaces an existing container with the same name.
set -euo pipefail
cd "$(dirname "$0")/.."
source config.env

[ -r "$CLUSTER_CERT_FILE" ] && [ -r "$CLUSTER_KEY_FILE" ] || { echo "missing $CLUSTER_CERT_FILE / $CLUSTER_KEY_FILE" >&2; exit 1; }

docker rm -f "$KONG_CONTAINER_NAME" >/dev/null 2>&1 || true

docker run -d --name "$KONG_CONTAINER_NAME" --restart unless-stopped \
  -e KONG_ROLE=data_plane \
  -e KONG_DATABASE=off \
  -e KONG_VITALS=off \
  -e KONG_KONNECT_MODE=on \
  -e KONG_CLUSTER_MTLS=pki \
  -e "KONG_CLUSTER_CONTROL_PLANE=$KONNECT_CP_HOST:443" \
  -e "KONG_CLUSTER_SERVER_NAME=$KONNECT_CP_HOST" \
  -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=$KONNECT_TP_HOST:443" \
  -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=$KONNECT_TP_HOST" \
  -e "KONG_CLUSTER_CERT=$(cat "$CLUSTER_CERT_FILE")" \
  -e "KONG_CLUSTER_CERT_KEY=$(cat "$CLUSTER_KEY_FILE")" \
  -e KONG_LUA_SSL_TRUSTED_CERTIFICATE=system \
  -p "$KONG_PROXY_PORT:8000" \
  -p "$KONG_PROXY_TLS_PORT:8443" \
  "$KONG_IMAGE"

echo "waiting for Konnect sync..."
for _ in $(seq 1 30); do
  docker logs "$KONG_CONTAINER_NAME" 2>&1 | grep -q 'sync v2 is enabled in CP' && { echo "connected to Konnect"; break; }
  sleep 2
done
code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$KONG_PROXY_PORT/" || true)
echo "proxy :$KONG_PROXY_PORT -> HTTP $code (404 = up, no routes yet)"
