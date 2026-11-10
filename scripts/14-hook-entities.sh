#!/usr/bin/env bash
# Step 14: Kong entities for the Claude Inference hooks route (Konnect hybrid CP).
# Creates/updates: service claude-hook -> HOOK_UPSTREAM_URL, route /claude-hook,
# plugins ip-restriction (Anthropic egress only) + key-auth (shared header),
# consumer "anthropic" with the key. Idempotent by name.
#
# Needs secrets/konnect.env (KONNECT_TOKEN=kpat_...) and secrets/hook.env:
#   HOOK_UPSTREAM_URL  e.g. http://10.0.12.34:8200  (the verdict server)
#   HOOK_ROUTE_PATH    e.g. /claude-hook
#   HOOK_KEY           random string; same value goes in claude.ai custom header x-hook-key
set -euo pipefail
cd "$(dirname "$0")/.."
source config.env
source secrets/konnect.env
source secrets/hook.env

api() { curl -fsS --connect-timeout 5 --max-time 30 -H "Authorization: Bearer $KONNECT_TOKEN" -H 'Content-Type: application/json' "$@"; }

cp_id=$(api "$KONNECT_API/v2/control-planes?page%5Bsize%5D=100" \
  | jq -r --arg h "$KONNECT_CP_HOST" '.data[] | select(.config.control_plane_endpoint | contains($h)) | .id' | head -1)
[ -n "$cp_id" ] || { echo "control plane for $KONNECT_CP_HOST not found" >&2; exit 1; }
base="$KONNECT_API/v2/control-planes/$cp_id/core-entities"
echo "control plane: $cp_id"

# upsert <entity-path> <name> <json-body>  (prints the id on stdout, progress on stderr)
upsert() {
  local path=$1 name=$2 body=$3 id
  id=$(api "$base/$path?size=1000" | jq -r --arg n "$name" '.data[] | select(.name==$n) | .id' | head -1)
  if [ -n "$id" ]; then
    api -X PATCH "$base/$path/$id" -d "$body" >/dev/null && echo "$path/$name updated ($id)" >&2
  else
    id=$(api -X POST "$base/$path" -d "$body" | jq -r .id) && echo "$path/$name created ($id)" >&2
  fi
  echo "$id"
}

# Service: short timeouts so the whole exchange stays inside Claude's 5000ms verdict budget.
# retries:0 — a Kong retry would stack another full timeout on top and blow the budget;
# Anthropic itself retries once on connection failure.
svc_body=$(jq -n --arg url "$HOOK_UPSTREAM_URL" '{name:"claude-hook", url:$url,
  connect_timeout:1000, read_timeout:3000, write_timeout:3000, retries:0}')
svc_id=$(upsert services claude-hook "$svc_body")

route_body=$(jq -n --arg p "$HOOK_ROUTE_PATH" --arg s "$svc_id" \
  '{name:"claude-hook", paths:[$p], methods:["POST","GET"], strip_path:true,
    service:{id:$s}, request_buffering:true, response_buffering:true}')
route_id=$(upsert routes claude-hook "$route_body")

# Plugin: only Anthropic's egress range may reach the route (not a substitute for the
# HMAC check in the verdict server; the range carries other Anthropic egress too).
# Behind an ALB, Kong sees the ALB's address: the DP must trust it and use the forwarded
# client IP (KONG_TRUSTED_IPS=<VPC CIDR>, KONG_REAL_IP_HEADER=X-Forwarded-For,
# KONG_REAL_IP_RECURSIVE=on), or use an NLB, which preserves the source IP.
plug() {  # plug <plugin-name> <config-json>
  local name=$1 config=$2 id body
  body=$(jq -n --arg n "$name" --arg r "$route_id" --argjson c "$config" \
    '{name:$n, enabled:true, route:{id:$r}, config:$c}')
  id=$(api "$base/plugins?size=1000" | jq -r --arg n "$name" --arg r "$route_id" \
    '.data[] | select(.name==$n and .route.id==$r) | .id' | head -1)
  if [ -n "$id" ]; then
    api -X PATCH "$base/plugins/$id" -d "$body" >/dev/null && echo "plugin $name updated ($id)"
  else
    api -X POST "$base/plugins" -d "$body" | jq -r '"plugin \(.name) created (\(.id))"'
  fi
}

plug ip-restriction '{"allow":["160.79.106.0/24"],"status":403,"message":"forbidden"}'
plug key-auth '{"key_names":["x-hook-key"],"key_in_header":true,"key_in_query":false,"key_in_body":false,"hide_credentials":true}'

# Consumer "anthropic" + its key (the same value is set in claude.ai as custom header x-hook-key).
consumer_id=$(api "$base/consumers?size=1000" | jq -r '.data[] | select(.username=="anthropic") | .id' | head -1)
if [ -z "$consumer_id" ]; then
  consumer_id=$(api -X POST "$base/consumers" -d '{"username":"anthropic"}' | jq -r .id)
  echo "consumer anthropic created ($consumer_id)"
fi
if ! api "$base/consumers/$consumer_id/key-auth?size=100" | jq -e --arg k "$HOOK_KEY" '.data[] | select(.key==$k)' >/dev/null; then
  api -X POST "$base/consumers/$consumer_id/key-auth" -d "$(jq -n --arg k "$HOOK_KEY" '{key:$k}')" >/dev/null
  echo "key-auth credential set for anthropic"
fi
# Key rotation: once the current key exists, revoke any older credentials so a retired
# key stops being accepted.
for old_id in $(api "$base/consumers/$consumer_id/key-auth?size=100" \
  | jq -r --arg k "$HOOK_KEY" '.data[] | select(.key!=$k) | .id'); do
  api -X DELETE "$base/consumers/$consumer_id/key-auth/$old_id"
  echo "revoked superseded key-auth credential ($old_id)"
done

echo "done: route $HOOK_ROUTE_PATH -> $HOOK_UPSTREAM_URL (ip-restriction + key-auth)"
