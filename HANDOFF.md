# Handoff — estado em 2026-10-21

## No ar
- **Kong Cloud** (Konnect, org SM4RT.ONE), CP `serverless-api-gateway-demo` (id 23cab37a-…), proxy
  `https://3fb7c42224.us.serverless.gateways.konggateway.com`. Estado declarado em `kong/kong-cloud.yaml` (decK): OTel global → Grafana,
  7 rotas (`/test` Kong-Bro, `/orders`, `/payments`, `/users`, `/catalog`, `/search` rate-limit 40/min, `/legacy` 503), key-auth, 5 consumers.
- **Gerador** `kong-traffic` (docker, restart unless-stopped) — `make traffic-stop` para parar.
- **Grafana Cloud** stack `orangestream1692` (prod-us-east-3, stack id 1885991): métricas OTel em Prometheus (`job="kong"`), logs Loki, traces Tempo.
  Dashboard público: https://orangestream1692.grafana.net/public-dashboards/add8116102804886a7a4ed6cacab98d8 (versão antiga; reimportar
  `dashboards/kong-command-center.json` com Overwrite corrige os painéis vazios).
- **DP self-hosted** `kong-dp` (AI Gateway `ai-gw-kong`, CP c0b1bf91b1) + Alloy local → Grafana (opcional, `make up`, `make alloy-up`).

## Pendências (ordem sugerida)
1. Reimportar o Command Center (Overwrite) e conferir que não há "No data"; investigar por que só `bro-test` aparece em `kong_route_name`
   (as rotas novas recebem tráfego — ver label real das séries).
2. `secrets/grafana-api.env` (service account Editor) → `make dashboards` (por API + link público).
3. Alertas + contact point + SLO no Grafana (ver `docs/GRAFANA-CLOUD.md`, checklist).
4. Rota de IA (AI Gateway model/provider) para popular `gen_ai_*` e testar `log_payloads` + AI Sanitizer (prompts no Loki).
5. Coolify (opcional): cert/key via base64 + init container; domínio `https://kong.s4z1.cloud:8000`.
6. Splunk e Looker Studio: seguir `docs/SPLUNK.md` / `docs/LOOKER-STUDIO.md` (não testados).

## Regras
- Commits sempre assinados (SSH signing já configurado; nunca desligar).
- Segredos só em `secrets/` (gitignored); fonte de verdade = 1Password, cache = keyring.
- Cada passo novo: seção no `RUNBOOK.md` + script/target no `Makefile` + commit.
- Respostas curtas (o Marcus está com pouco crédito); português.
