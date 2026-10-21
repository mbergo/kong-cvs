# Kong AI Gateway (Konnect hybrid) — runbook

Every step we run is recorded here and has a numbered script in `scripts/`.
Use the `Makefile` (`make help`); it calls the scripts with `sudo` (docker needs it on this host).

Settings: `config.env`. Secrets: `secrets/` (gitignored, never committed).

## Prerequisites
- Docker on the host (this host needs `sudo` for docker).
- Konnect control plane `c0b1bf91b1` (US region) and its data-plane certificate:
  `secrets/cluster.crt` + `secrets/cluster.key` (chmod 600).
  Source: Konnect → Gateway Manager → control plane → Data Plane Nodes → New node.

## Steps

### 01 — Start the data plane (2026-10-21)
`make up` (= `sudo scripts/01-run-dataplane.sh`). Check with `make check`, `make status`, `make logs`.

- Runs `kong/kong-ai-gateway:2.2.0-distroless` as `kong-dp`, role `data_plane`, DB-less, Konnect mode.
- Ports: 8000 (proxy), 8443 (proxy TLS).
- Check: log line `sync v2 is enabled in CP` = connected; `curl localhost:8000` → 404 until routes exist.
- Origin: the manual `~/kong.sh` (pasted from Konnect), run with `sudo bash ./kong.sh`.
  Without sudo the containers were only created, never started (`make clean-stale` removes them).
  The original pasted script is kept as `secrets/kong.sh.original` (gitignored: it embeds the private key).

### 01b — Expose the status/metrics endpoint (2026-10-21)
`scripts/01-run-dataplane.sh` now sets `KONG_STATUS_LISTEN=0.0.0.0:8100` and publishes it on
`127.0.0.1:8100` only. Re-run `make up` to apply (recreates `kong-dp`, a few seconds of downtime).

### 02 — Enable Prometheus metrics in Konnect (pending: Konnect token)
`make prometheus-plugin`

- Needs `secrets/konnect.env` with `KONNECT_TOKEN=kpat_...`
  (Konnect → profile → Personal Access Tokens). Requires `jq`.
- Finds the control plane by `KONNECT_CP_HOST` and creates/updates a **global** `prometheus` plugin
  with status-code, latency, bandwidth, upstream-health and **AI** metrics (tokens, cost per provider/model).
- Check: `make metrics` shows `kong_*` series (AI series appear after the first AI-proxy request).

### 03 — Ship metrics to Grafana Cloud (done 2026-10-21)
`make alloy-up`

- Needs `secrets/grafana.env` with `GRAFANA_PROM_URL`, `GRAFANA_PROM_USER`, `GRAFANA_PROM_TOKEN`
  (Grafana Cloud → Connections → Hosted Prometheus metrics → single instance → Directly →
  Create token, scope `set:alloy-data-write`; copy url/username/password from the generated config).
- Runs `grafana/alloy` on the host network, scraping `127.0.0.1:8100/metrics` every 15s (`alloy/config.alloy`).
- Check: `curl -s 127.0.0.1:12345/metrics | grep remote_storage_samples` (failed_total must be 0);
  in Grafana Explore, query `kong_control_plane_connected`.

### 04 — Dashboard (next)
Import the official Kong dashboard (grafana.com ID 7424) and add an AI panel set (tokens/cost by provider and model).

### 05 — Public URL via ngrok (2026-10-21)
`ngrok http 8000` (binary in `~/.local/bin`; brew cask is macOS-only:
`curl -fsSL https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz | tar xz`).
Authtoken: `ngrok config add-authtoken <token>` (dashboard.ngrok.com → Your Authtoken).
Public URL from `curl -s 127.0.0.1:4040/api/tunnels | jq -r '.tunnels[0].public_url'`.
MCP (Streamable HTTP) endpoint = `<public_url>/<route path with AI MCP Proxy>`, e.g. `/mcp`.

### 01c — TLS verify for plugins (2026-10-21, TEST ONLY)
Symptom: Konnect shows the node "Out of sync" / "Sync deltas parse failure (error code 21)";
`make logs` shows `ssl_verify invalid value: global tls_certificate_verify option is enabled`.
A plugin with `ssl_verify: false` makes the DP reject the whole config. For test, `config.env`
sets `KONG_TLS_CERTIFICATE_VERIFY=off` (script default is `on`); then `make up`.
In prod keep `on` and turn `ssl_verify` back on in the plugin instead.

### 06 — Host on Coolify (xyz.s4z1.cloud)
Everything deploys from this repo; only secrets are set in Coolify.

1. Coolify → project → **+ New → Private Repository (with GitHub App)** → pick `mbergo/kong-cvs`, branch `main`.
2. Build pack **Docker Compose**, compose file `/docker-compose.yml`.
3. Environment variables (see `.env.example`): `KONG_CLUSTER_CERT`, `KONG_CLUSTER_CERT_KEY`
   (contents of `secrets/cluster.crt|key`, mark *Is Multiline*), `GRAFANA_PROM_URL`, `GRAFANA_PROM_USER`,
   `GRAFANA_PROM_TOKEN` (from `secrets/grafana.env`). Test only: `KONG_TLS_CERTIFICATE_VERIFY=off`.
4. Domain on service `kong-dp` (port 8000), e.g. `https://kong.s4z1.cloud` → **Deploy**.
5. Check: Konnect shows a new DP node "In sync"; Grafana Explore `kong_control_plane_connected{instance="coolify"}` = 1.

Don't use Coolify's Kong one-click template: it runs a standalone Kong with its own DB, not a Konnect DP.

### 07 — OpenTelemetry push to Grafana Cloud (2026-10-21)
For Kong-hosted data planes (Serverless/Dedicated) where :8100 can't be scraped. Works on any DP.
Konnect → control plane (e.g. `serverless-api-gateway-demo`) → Plugins → **OpenTelemetry** → Global:
- Traces `https://otlp-gateway-prod-us-east-3.grafana.net/otlp/v1/traces`
- Logs and Access logs `https://otlp-gateway-prod-us-east-3.grafana.net/otlp/v1/logs`
- Metrics `https://otlp-gateway-prod-us-east-3.grafana.net/otlp/v1/metrics`, push interval 15,
  request/bandwidth/latency/upstream-health/**AI** metrics on.
- Additional settings → Headers: `Authorization` = value of `GRAFANA_OTLP_AUTH_HEADER` in
  `secrets/grafana-otlp.env` (`Basic base64(<stack id 1885991>:<glc token with metrics/logs/traces:write>)`),
  **no quotes** in the form field.
Token: Grafana Cloud → Connections → OpenTelemetry (OTLP) → Minimal setup → create token.
