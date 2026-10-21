# Kong AI Gateway (Konnect hybrid) — runbook

Every step we run is recorded here and has a numbered script in `scripts/`.
Run scripts from the repo root with `sudo` (docker needs it on this host).

Settings: `config.env`. Secrets: `secrets/` (gitignored, never committed).

## Prerequisites
- Docker on the host (this host needs `sudo` for docker).
- Konnect control plane `c0b1bf91b1` (US region) and its data-plane certificate:
  `secrets/cluster.crt` + `secrets/cluster.key` (chmod 600).
  Source: Konnect → Gateway Manager → control plane → Data Plane Nodes → New node.

## Steps

### 01 — Start the data plane (2026-10-21)
`sudo scripts/01-run-dataplane.sh`

- Runs `kong/kong-ai-gateway:2.2.0-distroless` as `kong-dp`, role `data_plane`, DB-less, Konnect mode.
- Ports: 8000 (proxy), 8443 (proxy TLS).
- Check: log line `sync v2 is enabled in CP` = connected; `curl localhost:8000` → 404 until routes exist.
- Origin: the manual `~/kong.sh` (pasted from Konnect), run with `sudo bash ./kong.sh`.
  Without sudo the containers were only created, never started.
