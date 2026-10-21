#!/usr/bin/env bash
# Step 12: publish dashboards to Grafana Cloud by API (idempotent, overwrite by uid) and share the
# executive one publicly. Needs secrets/grafana-api.env:
#   GRAFANA_URL=https://<stack>.grafana.net   GRAFANA_API_TOKEN=glsa_...  (service account, role Editor)
set -euo pipefail
cd "$(dirname "$0")/.."
source secrets/grafana-api.env
g() { curl -fsS -H "Authorization: Bearer $GRAFANA_API_TOKEN" -H 'Content-Type: application/json' "$@"; }

folder=$(g "$GRAFANA_URL/api/folders" | jq -r '.[] | select(.title=="Kong") | .uid')
[ -n "$folder" ] || folder=$(g -X POST "$GRAFANA_URL/api/folders" -d '{"title":"Kong"}' | jq -r .uid)

for f in dashboards/kong.json dashboards/kong-public.json; do
  jq -n --slurpfile d "$f" --arg folder "$folder" '{dashboard: ($d[0] | del(.id)), folderUid: $folder, overwrite: true}' \
    | g -X POST "$GRAFANA_URL/api/dashboards/db" -d @- | jq -r '"  \(.url)"'
done

# Official Kong dashboard 7424 (Prometheus plugin, self-hosted DPs)
curl -fsSL https://grafana.com/api/dashboards/7424/revisions/latest/download \
  | jq --arg folder "$folder" '{dashboard: (. | del(.id)), folderUid: $folder, overwrite: true,
       inputs: [{name: "DS_PROMETHEUS", type: "datasource", pluginId: "prometheus", value: "grafanacloud-prom"}]}' \
  | g -X POST "$GRAFANA_URL/api/dashboards/import" -d @- | jq -r '"  \(.importedUrl // .url)"'

# Public link for the executive dashboard
uid=kong-exec-public
pub=$(g "$GRAFANA_URL/api/dashboards/uid/$uid/public-dashboards" 2>/dev/null | jq -r '.accessToken // empty' || true)
[ -n "$pub" ] || pub=$(g -X POST "$GRAFANA_URL/api/dashboards/uid/$uid/public-dashboards" \
  -d '{"isEnabled":true,"share":"public","timeSelectionEnabled":true}' | jq -r .accessToken)
echo "public: $GRAFANA_URL/public-dashboards/$pub"
