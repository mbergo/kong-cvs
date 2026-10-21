#!/usr/bin/env bash
# Step 11: demo services/routes/consumers on the Kong Cloud (serverless) control plane, for varied traffic.
# Idempotent: PUT by name; plugins and credentials are only created when missing.
set -euo pipefail
cd "$(dirname "$0")/.."
source config.env; source secrets/konnect.env
CP_NAME="${DEMO_CP_NAME:-serverless-api-gateway-demo}"
api() { curl -fsS -H "Authorization: Bearer $KONNECT_TOKEN" -H 'Content-Type: application/json' "$@"; }
cp_id=$(api "$KONNECT_API/v2/control-planes?filter%5Bname%5D%5Beq%5D=$CP_NAME" | jq -r '.data[0].id')
B="$KONNECT_API/v2/control-planes/$cp_id/core-entities"
echo "control plane $CP_NAME: $cp_id"

has_plugin() { api "$B/services/$1/plugins" | jq -e --arg n "$2" '.data[] | select(.name==$n)' >/dev/null; }

for svc in orders payments users catalog search legacy; do
  api -X PUT "$B/services/$svc-api" -d "{\"name\":\"$svc-api\",\"url\":\"https://httpbin.org\"}" >/dev/null
  api -X PUT "$B/services/$svc-api/routes/$svc" -d "{\"name\":\"$svc\",\"paths\":[\"/$svc\"]}" >/dev/null
  has_plugin "$svc-api" key-auth || api -X POST "$B/services/$svc-api/plugins" -d '{"name":"key-auth","config":{"key_names":["apikey"]}}' >/dev/null
  echo "  $svc-api → /$svc"
done
has_plugin search-api rate-limiting || api -X POST "$B/services/search-api/plugins" \
  -d '{"name":"rate-limiting","config":{"minute":40,"policy":"local"}}' >/dev/null
has_plugin legacy-api request-termination || api -X POST "$B/services/legacy-api/plugins" \
  -d '{"name":"request-termination","config":{"status_code":503,"message":"legacy-api is being decommissioned"}}' >/dev/null

touch secrets/demo-consumers.env; chmod 600 secrets/demo-consumers.env
for c in mobile-app web-app partner-acme internal-batch; do
  api -X PUT "$B/consumers/$c" -d "{\"username\":\"$c\"}" >/dev/null
  var="KEY_$(echo "$c" | tr 'a-z-' 'A-Z_')"
  key=$(grep "^$var=" secrets/demo-consumers.env | cut -d= -f2- || true)
  if [ -z "$key" ]; then
    key="demo-$c-$(openssl rand -hex 12)"
    api -X POST "$B/consumers/$c/key-auth" -d "{\"key\":\"$key\"}" >/dev/null
    echo "$var=$key" >> secrets/demo-consumers.env
  fi
  echo "  consumer $c"
done
