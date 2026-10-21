#!/usr/bin/env bash
# From zero: Kong Cloud (Konnect serverless) + Grafana Cloud observability, fully by CLI.
#   needs: deck, jq, curl, openssl, docker; secrets/konnect.env (KONNECT_TOKEN) and
#          secrets/grafana-otlp.env (GRAFANA_OTLP_AUTH_HEADER="Basic base64(stack_id:glc_token)")
# Steps: generate consumer keys → decK diff/sync kong/kong-cloud.yaml → smoke test → traffic generator.
set -euo pipefail
cd "$(dirname "$0")/.."
for t in deck jq curl openssl docker; do command -v $t >/dev/null || { echo "missing $t" >&2; exit 1; }; done
source config.env; source secrets/konnect.env; source secrets/grafana-otlp.env

# 1. consumer API keys (generated once, kept in secrets/)
touch secrets/demo-consumers.env; chmod 600 secrets/demo-consumers.env
for c in BRO MOBILE_APP WEB_APP PARTNER_ACME INTERNAL_BATCH; do
  grep -q "^KEY_$c=" secrets/demo-consumers.env || echo "KEY_$c=demo-$(openssl rand -hex 16)" >> secrets/demo-consumers.env
done
source secrets/demo-consumers.env
export DECK_OTLP_AUTH="$GRAFANA_OTLP_AUTH_HEADER" DECK_KEY_BRO="$KEY_BRO" DECK_KEY_MOBILE_APP="$KEY_MOBILE_APP" DECK_KEY_WEB_APP="$KEY_WEB_APP" \
       DECK_KEY_PARTNER_ACME="$KEY_PARTNER_ACME" DECK_KEY_INTERNAL_BATCH="$KEY_INTERNAL_BATCH"

# 2. apply the declarative config
D=(--konnect-token "$KONNECT_TOKEN" --konnect-addr "$KONNECT_API")
deck gateway diff "${D[@]}" kong/kong-cloud.yaml
deck gateway sync "${D[@]}" kong/kong-cloud.yaml

# 3. smoke test
CP=$(curl -fsS -H "Authorization: Bearer $KONNECT_TOKEN" "$KONNECT_API/v2/control-planes?filter%5Bname%5D%5Beq%5D=serverless-api-gateway-demo" | jq -r '.data[0].id')
PROXY="${KONG_SERVERLESS_URL:-https://3fb7c42224.us.serverless.gateways.konggateway.com}"
grep -q '^KONG_SERVERLESS_URL=' secrets/tester.env 2>/dev/null || echo "KONG_SERVERLESS_URL=$PROXY" >> secrets/tester.env
echo "control plane $CP, proxy $PROXY"
sleep 10
for r in test orders payments users catalog search legacy; do
  printf '  /%-9s no key %s | key %s\n' "$r" "$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/$r/get")" \
    "$(curl -s -o /dev/null -w '%{http_code}' -H "apikey: $KEY_WEB_APP" "$PROXY/$r/get")"
done

# 4. traffic + dashboards
make traffic
echo "Dashboards: import dashboards/kong-public.json (and grafana.com 7424 for self-hosted) in Grafana."
