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
- Check: `curl -s 127.0.0.1:12346/metrics | grep remote_storage_samples` (failed_total must be 0;
  port moved 12345→12346, the default clashes with guardrail-observer's Alloy on this host);
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

### 08 — Serverless gateway: route + key auth (2026-10-21)
Control plane `serverless-api-gateway-demo`, proxy `https://3fb7c42224.us.serverless.gateways.konggateway.com`.
- Gateway service **Kong-Bro** → upstream `httpbin.org`; route path `/test` (methods and hosts empty).
- Consumer **bro**: first created as a central consumer in the UI; now also a CP consumer with `KEY_BRO`
  (`secrets/demo-consumers.env`), managed by decK in `kong/kong-cloud.yaml`.
- Plugin **Key Authentication** scoped to Kong-Bro: key names `apikey`, key in header (+query), auth by
  **Centrally managed consumers**, realms `Current control plane` + `bro`.
- Check: no key → 401; `-H "apikey: $KONG_TESTER_APIKEY"` → 200 with `X-Consumer-Username: bro`.

### 09 — Grafana dashboard (2026-10-21)
`dashboards/kong.json` → Grafana → Dashboards → New → **Import** → upload (or paste
`https://raw.githubusercontent.com/mbergo/kong-cvs/main/dashboards/kong.json`) → pick the
`...-prom`, `...-traces`, `...-logs` data sources in the variables at the top.
- Kong Cloud row: TraceQL metrics on `resource.service.name="kong"` (rate by status/route, p50/p95, errors) + Loki logs.
- Self-hosted row: Prometheus plugin metrics scraped by Alloy.
- AI row: `kong_ai_llm_*` (empty until traffic goes through an AI model route).

### 10 — Synthetic traffic generator (2026-10-21)
`make traffic` runs `scripts/10-traffic-gen.sh` in a `curlimages/curl` container (restart unless-stopped):
7 routes × 5 consumers + anonymous, GET/POST/PUT/DELETE, 2xx/4xx/5xx, `/delay` latency, `/bytes` payloads,
~3 req/s with a `/search` burst every ~10 min (trips the rate limit). Needs `secrets/demo-consumers.env` and
`KONG_SERVERLESS_URL` in `secrets/tester.env`. Stop with `make traffic-stop`.

### 09b — Executive dashboard
`dashboards/kong.json` (uid `kong-exec`) uses the Kong OTel metric names as Prometheus sees them
(`http_server_request_count_total`, `kong_latency_*_seconds_bucket`, `http_server_*_size_bytes`,
`gen_ai_client_token_usage_total`, `kong_gen_ai_llm_cost_total`). Variables: data sources, gateway (`job`), consumer.
Rows: executive KPIs, traffic & reliability, who/what, AI, and collapsed traces/logs + self-hosted.

### 09c — Public (shareable) dashboard
Grafana public dashboards don't support template variables, so `dashboards/kong-public.json` is the same
dashboard with variables resolved (Grafana Cloud default data source UIDs `grafanacloud-prom|traces|logs`,
gateway `kong`, all consumers). Import it, then **Share → Share externally → Public dashboard** → copy link.

### 13 — Claude Inference hooks: verdict server (2026-11-02)
`make hook-server` (= `scripts/13-hook-server.py`), listens on :8200.

Inference hooks = Claude Enterprise sends every governed prompt (and tool call) as a signed
HTTPS POST to **our** endpoint and waits for `{"action":"allow"}` or `{"action":"deny",...}`
before inference runs. Kong proxies that POST to this verdict server.

```
                    ANTHROPIC SIDE                                   OUR SIDE (AWS)
┌──────────────────────────────────────────────┐   ┌─────────────────────────────────────────────┐
│ claude.ai / Claude Code / Cowork users       │   │        Route53  hook.example.com            │
│        │ prompt                              │   │           │                                 │
│        ▼                                     │   │           ▼                                 │
│ Anthropic inference pipeline                 │   │  ALB :443 (ACM cert, no redirects)          │
│   │  signed POST (prompt/tool_call frame)    │   │           │                                 │
│   │  from 160.79.106.0/24                    │   │           ▼                                 │
│   └─────────────────────────────────────────────▶│  Kong DP (EC2/EKS)  route /claude-hook      │
│   ◀─ waits ≤ verdict timeout (default 5s) ──────│   plugins: ip-restriction(160.79.106.0/24)  │
│        │                                     │   │            key-auth(x-hook-key)             │
│        ▼                                     │   │            prometheus (global, step 02)     │
│  allow → model runs                          │   │           │                                 │
│  deny  → user sees deny_reason               │   │           ▼                                 │
│                                              │   │  verdict server :8200                       │
│ CONTROL PLANE #1: claude.ai Org settings     │   │   HMAC verify (whsec_…) + policy            │
│  Data and privacy → Inference hooks          │   │   HOOK_MODE = enforce | alert | off         │
│  (Enforce verdicts, Shadow, failure, %)      │   │                                             │
└──────────────────────────────────────────────┘   │ CONTROL PLANE #2: Konnect (c0b1bf91b1)      │
                                                   │  service/route/plugins via script 14        │
                                                   └─────────────────────────────────────────────┘
```

Two independent mode switches:
- **Anthropic control plane** (claude.ai → Organization settings → Data and privacy →
  Inference hooks, needs Owner/Primary owner): Off (Enforce verdicts off) / **Shadow mode**
  (verdicts flow, nothing blocked) / Enforcing (Mode = Allow or Block the request).
- **Our side** `HOOK_MODE` in `secrets/hook.env`: `enforce` (policy hit → deny),
  `alert` (policy hit → log ALERT, return allow), `off` (allow everything).

Golden rule: on our side, "off"/"alert" ALWAYS mean "return 200 allow", never a 403/503 —
any non-200 from Kong or the server is a *webhook failure*, which triggers the org's
Failure handling (fail-open or fail-closed) and counts toward Anthropic's circuit breaker.

Config: `secrets/hook.env` (gitignored) with `HOOK_SIGNING_SECRET=whsec_…` (shown ONCE in
claude.ai, step 15), `HOOK_MODE=alert`, `HOOK_PORT=8200`, plus `HOOK_UPSTREAM_URL`,
`HOOK_ROUTE_PATH=/claude-hook`, `HOOK_KEY=<random>` for step 14. `HOOK_MODE` and the secret
are read at startup — restart the server to apply a change. Without a secret the server
refuses to start (`HOOK_ALLOW_UNSIGNED=1` overrides, local tests only).
Demo policy = 3 regexes in the script; swap for the real engine (Fiddler, etc.).
Check: `curl -s localhost:8200` → `{"status":"ok","mode":"alert"}`.

### 14 — Claude Inference hooks: Kong route + plugins (2026-11-02)
`make hook-entities` (= `scripts/14-hook-entities.sh`), Konnect API, idempotent.

- Prereq: the AWS front door (Route53 + ALB + ACM cert + the deployed verdict server) is
  existing infrastructure — this script only wires Kong; it creates nothing in AWS.
- Service `claude-hook` → `HOOK_UPSTREAM_URL`, timeouts 1000/3000/3000ms, retries 0
  (everything must fit in Claude's verdict budget, default 5000ms for the WHOLE exchange
  incl. TLS handshake; a Kong retry would stack another timeout on top, and Anthropic
  already retries once on connection failure).
- Route `/claude-hook` (strip_path), plugins scoped to it:
  `ip-restriction` allow `160.79.106.0/24` (Anthropic egress; defense in depth, the HMAC
  check in the server is the real authentication) and `key-auth` on header `x-hook-key`
  (consumer `anthropic`; same value configured in claude.ai as a custom request header).
  Rerunning the script after changing `HOOK_KEY` rotates the credential: old keys are revoked.
- Real IP behind the ALB: Kong sees the ALB's address, so `ip-restriction` would 403
  everything. Set on the DP: `KONG_TRUSTED_IPS=<VPC CIDR>`, `KONG_REAL_IP_HEADER=X-Forwarded-For`,
  `KONG_REAL_IP_RECURSIVE=on` — or use an NLB (TCP passthrough preserves the source IP,
  TLS then terminates on Kong with a public-CA cert).
- AWS front door requirements (hard, from Anthropic): `https://` on port 443, public IPv4,
  cert from a public CA (ACM on the ALB), **no redirects** (the configured URL answers
  directly), no ngrok/tunnels (blocked — step 05's ngrok does NOT work here). Transcripts
  are sent untruncated: allow bodies up to 64 MiB end to end (ALB is fine; do NOT front
  this with AWS API Gateway, 10 MB hard limit; mind nginx `client_max_body_size` if another
  proxy sits in the path — Kong's default is unlimited).
- Check: `curl -s https://hook.example.com/claude-hook` → 403 (ip-restriction) from a
  laptop is expected; from an allowed source without the key → 401; claude.ai
  **Test connection** (step 15) is the real end-to-end check.

### 15 — Claude Inference hooks: Anthropic control plane (claude.ai)
No script — UI only, needs the **Owner** or **Primary owner** role (`organization:manage`).
claude.ai → **Organization settings → Data and privacy → Inference hooks**:

1. **Allow for your organization** on (this alone inspects nothing; it always forces
   Enforce verdicts off).
2. **Configure** → Endpoint URL `https://hook.example.com/claude-hook` → Next.
3. Copy the **signing secret** (`whsec_…`, shown once, only rotatable later) →
   `secrets/hook.env` `HOOK_SIGNING_SECRET`, restart the verdict server.
4. **Custom request headers**: add `x-hook-key` = `HOOK_KEY` (values are write-only;
   changing the URL clears them). **Test connection** → should report an *allow* verdict
   and the measured round trip.
5. **Failure handling**: Mode **Allow the request** (fail-open) to start; timeout 5000ms.
   Flip to **Block the request** (fail-closed) only when the server is proven stable.
6. **Rollout**: Requests inspected (%) — start 10%, then 100%.
7. Turn on **Enforce verdicts** with Mode = **Shadow mode** first ("alert" at the
   Anthropic level: verdicts flow, nothing blocked, badge "Shadow mode — not blocking").
   **Validate tool calls** on (default) also sends tool_call frames.
8. Go live: Mode → Allow/Block the request. Changes propagate in ~1 min.

Rollout ladder (safe order): 13 server in `alert` → 14 route → 15.1–15.6 with Shadow 10%
→ Shadow 100% (tune policy on real traffic, nothing blocks) → `HOOK_MODE=enforce` +
claude.ai Mode=Allow the request (denies now block; webhook failures fail open) →
optionally Failure handling=Block the request (fail-closed).

Ops notes: claude.ai shows endpoint health (status, failures/min, block rate, recent
errors, circuit breaker). Sustained failures trip the **circuit breaker** → our server
stops being called and Failure handling applies to everything; auto-recovery probes
(`source.application=config-test`) start after 10 min, or reset by toggling Enforce
verdicts. Denials land in the Activity Feed as `inference_hooks_request_denied` with our
`reference_id` → joinable to the server's JSONL log. Kong side: the route shows up in the
step 02/07 Prometheus/OTel metrics and the step 09 dashboards like any other route.
Docs: platform.claude.com/docs/en/manage-claude/inference-hooks{,-configuration,-endpoint}.

## From zero (Kong Cloud + Grafana Cloud), all CLI
1. `secrets/konnect.env` (KONNECT_TOKEN=kpat_…, org with the serverless CP),
   `secrets/grafana-otlp.env` (GRAFANA_OTLP_AUTH_HEADER), `secrets/grafana-api.env` (GRAFANA_URL, GRAFANA_API_TOKEN).
2. `make cloud` → decK sync `kong/kong-cloud.yaml` (OTel global, 7 APIs, key-auth, rate limit, 503 legacy,
   5 consumers; keys generated into `secrets/demo-consumers.env`), smoke test, starts `make traffic`.
3. `make dashboards` → Grafana folder "Kong": executive dashboard, public variant (+ public link), official 7424.
`make cloud-diff` shows drift between Kong Cloud and the file.
