# Kong → Grafana Cloud (o que fizemos, passo a passo, e o que falta)

## Arquitetura

```
cliente → Kong Cloud (serverless) ──OTLP/HTTP──► Grafana Cloud OTLP gateway
                                                   ├─ Prometheus (métricas)  → dashboards, alertas
                                                   ├─ Loki (logs de acesso)  → busca, prompts (se ligado)
                                                   └─ Tempo (traces)          → latência por requisição
```

Sem agente nem servidor: o Kong **empurra** os dados. Para data plane self-hosted existe a alternativa pull (plugin Prometheus + Grafana Alloy), descrita no [`RUNBOOK.md`](../RUNBOOK.md).

## Passo a passo (o que fizemos)

1. **Grafana Cloud**: Connections → Add new connection → **OpenTelemetry (OTLP)** → *Minimal setup*.
   - Endpoint da região: `https://otlp-gateway-<região>.grafana.net/otlp` (o nosso: `prod-us-east-3`).
   - Crie um token com os escopos `metrics:write`, `logs:write` e `traces:write`.
   - Header: `Authorization: Basic base64(<stack_id>:<token>)`. A tela mostra o valor pronto, com `%20` no lugar do espaço.
2. **Kong (Konnect)**: Control plane → Plugins → **OpenTelemetry** → **Global**:
   - Traces: `…/otlp/v1/traces`. Logs e Access logs: `…/otlp/v1/logs`. Metrics: `…/otlp/v1/metrics`, push interval `15`.
   - Ligue: request, latency, bandwidth, upstream health, consumer attribute e **AI metrics**.
   - Additional settings → Headers: `Authorization` = `Basic <valor>`, com **espaço normal, sem `%20` e sem aspas**.
   - Por CLI: `kong/kong-cloud.yaml` + `make cloud` (decK).
3. **Tráfego**: rotas com key auth e consumers (`make cloud`), e o gerador `make traffic`.
4. **Conferir os dados**: Grafana → Observability → Application → o serviço **`kong`** aparece. Para métricas, vá ao Explore e consulte `http_server_request_count_total{job="kong"}`.
5. **Dashboard**: importe `dashboards/kong-command-center.json` (Dashboards → New → Import → cole o JSON → escolha o `…-prom`).
6. **Link público**: Share → Share externally → Anyone with the link.

## Nomes que importam

| OTel (Kong) | Como aparece no Prometheus |
|---|---|
| `http.server.request.count` | `http_server_request_count_total` |
| `kong.latency.total` / `.upstream` / `.internal` | `kong_latency_total_seconds_bucket` / `kong_latency_upstream_seconds_bucket` / `kong_latency_internal_seconds_bucket` |
| `http.server.request.size` / `response.size` | `http_server_request_size_bytes_*` / `http_server_response_size_bytes_*` |
| `gen_ai.client.token.usage` | `gen_ai_client_token_usage_total` |
| `kong.gen_ai.llm.cost` | `kong_gen_ai_llm_cost_total` |
| atributo `service.name=kong` | label `job="kong"` |
| status code | label `http_response_status_code` |

## Pegadinhas que já resolvemos

- **`config.logs_endpoint - missing host in url`**: o campo tinha espaço ou aspas. Cole a URL pura.
- **Data plane "Out of sync" / "Sync deltas parse failure (error code 21)"**: algum plugin com `ssl_verify: false` e o data plane com `tls_certificate_verify` ligado. Ligue o `ssl_verify` de novo, ou (só em teste) use `KONG_TLS_CERTIFICATE_VERIFY=off`.
- **Dashboard público com "No data"**: dashboards públicos não aceitam variáveis e devolvem vazio em queries *instant/table*. Use queries de range com *reduce* (o Command Center já está assim).
- **Import "Not valid JSON"**: o campo de URL do import só aceita grafana.com. Cole o JSON na caixa grande.
- **App Observability com "No Data" em latência e erros**: esses painéis dependem de métricas derivadas de traces, que levam de 5 a 10 minutos para aparecer depois do primeiro tráfego.

## O que ainda falta (checklist)

| Item | Por quê | Como |
|---|---|---|
| **Plano pago ou retenção** | O trial do Grafana Cloud acaba em 14 dias, e o do Konnect em 30 | Grafana: Free (10k séries, 50 GB de logs, 14 dias de retenção) ou Pro. Konnect: plano pago |
| **Alertas** | Hoje ninguém é avisado | Alerting → regras: sucesso < 95% por 5 min, p95 > 1,5 s, 5xx > 5%, `kong_cp_connection_status == 0` |
| **Contact point** | Saber para onde vai o alerta | Alerting → Contact points: Slack, Teams ou e-mail |
| **SLO** | Mostrar para a gestão o "99,x% de disponibilidade" | Observability → SLO: indicador = 2xx+3xx / total, `job="kong"` |
| **Dashboard de AI** | Os painéis `gen_ai_*` ficam vazios sem uma rota de IA | Crie um model/provider no AI Gateway e mande tráfego |
| **Prompts (se exigido)** | Auditoria | AI Proxy `logging.log_payloads: true`. Os prompts vão para o Loki pelo OTel. **Mascare PII antes** (AI Sanitizer) |
| **Acesso** | Hoje só você entra | Administration → Users/Teams. Viewer para a gestão, Editor para o time |
| **Dashboard como código** | Para não depender de import manual | Service account (Editor) + `make dashboards` (por API, com link público) |
| **Custo de cardinalidade** | `kong_auth_consumer_name` e `kong_route_name` multiplicam as séries | Cost Management → Cardinality. Desligue `per_consumer` se crescer demais |
| **Token do OTLP** | Hoje está "No expiry" e em texto puro no plugin | Use um Vault do Konnect (`{vault://...}`) no header e defina uma validade |
| **Sampling de traces** | Volume e custo em produção | Plugin OTel: `sampling_rate` (ex.: 0.1) |
