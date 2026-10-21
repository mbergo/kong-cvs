#!/usr/bin/env bash
# Step 02: enable the global Prometheus plugin (incl. AI metrics) on the Konnect control plane.
# Idempotent: creates the plugin, or updates its config if it already exists.
set -euo pipefail
cd "$(dirname "$0")/.."
source config.env
source secrets/konnect.env   # KONNECT_TOKEN=kpat_...

api() { curl -fsS -H "Authorization: Bearer $KONNECT_TOKEN" -H 'Content-Type: application/json' "$@"; }

cp_id=$(api "$KONNECT_API/v2/control-planes?page%5Bsize%5D=100" \
  | jq -r --arg h "$KONNECT_CP_HOST" '.data[] | select(.config.control_plane_endpoint | contains($h)) | .id' | head -1)
[ -n "$cp_id" ] || { echo "control plane for $KONNECT_CP_HOST not found" >&2; exit 1; }
echo "control plane: $cp_id"

base="$KONNECT_API/v2/control-planes/$cp_id/core-entities/plugins"
body='{"name":"prometheus","enabled":true,"config":{
  "status_code_metrics":true,"latency_metrics":true,"bandwidth_metrics":true,
  "upstream_health_metrics":true,"per_consumer":false,"ai_metrics":true}}'

existing=$(api "$base?size=1000" | jq -r '.data[] | select(.name=="prometheus" and .service==null and .route==null and .consumer==null) | .id' | head -1)
if [ -n "$existing" ]; then
  api -X PATCH "$base/$existing" -d "$body" >/dev/null && echo "prometheus plugin updated ($existing)"
else
  api -X POST "$base" -d "$body" | jq -r '"prometheus plugin created (\(.id))"'
fi
