# Arquitetura: quem fala com quem, em cada caso

Para cada destino: os componentes, o diagrama e **todas as conexões** (origem → destino, protocolo, quem inicia, autenticação e o que trafega). A configuração está nos guias de cada destino ([Grafana](GRAFANA-CLOUD.md), [Splunk](SPLUNK.md), [Looker Studio](LOOKER-STUDIO.md)).

## Componentes comuns

| Componente | O que é | Onde roda |
|---|---|---|
| **Cliente** | app, `curl` ou o gerador `kong-traffic` | qualquer lugar |
| **Konnect Control Plane (CP)** | guarda a configuração (rotas, plugins, consumers) e a distribui | Kong Cloud (SaaS) |
| **Data Plane (DP)** | o gateway que recebe o tráfego e executa os plugins | Kong Cloud *serverless* (gerenciado) ou self-hosted (Docker/K8s) |
| **Upstream** | a API de verdade (aqui, `httpbin.org`; em produção, os serviços e os LLMs) | qualquer lugar |
| **decK / Konnect UI** | aplica a configuração no CP | sua máquina ou CI |
| **Plugin de observabilidade** | roda **dentro do DP** e emite os dados (OpenTelemetry, HTTP Log, Prometheus) | dentro do DP |

Base, comum a todos os casos:

```mermaid
flowchart LR
  dev[decK / Konnect UI] -- HTTPS 443 · PAT kpat_ --> cp[Konnect Control Plane]
  cp -- config push · mTLS / gerenciado --> dp[Data Plane]
  cli[Cliente] -- HTTPS 443 · header apikey --> dp
  dp -- HTTPS 443 --> up[Upstream / LLM]
  dp -. telemetria Konnect .-> cp
```

| # | De → Para | Protocolo | Quem inicia | Auth | Trafega |
|---|---|---|---|---|---|
| 1 | decK/UI → CP | HTTPS 443 (Konnect API) | decK | Personal/System Access Token | configuração declarativa |
| 2 | CP → DP | WSS/HTTPS 443 | **DP** (abre a conexão com o CP) | mTLS (cert do cluster) ou gerenciado (serverless) | configuração |
| 3 | Cliente → DP | HTTPS 443 (proxy 8000/8443 se self-hosted) | cliente | Key Auth (`apikey`), OIDC etc. | requisição |
| 4 | DP → Upstream | HTTPS 443 | DP | a do upstream (ex.: API key do LLM, injetada pelo AI Proxy) | requisição e resposta |
| 5 | DP → CP (telemetria) | HTTPS 443 (`*.tp.konghq.com`) | DP | mTLS | analytics do Konnect |

---

## 1. Grafana Cloud: push via OpenTelemetry (o que está no ar)

```mermaid
flowchart LR
  cli[Cliente] --> dp[DP Kong Cloud serverless]
  dp --> up[Upstream]
  subgraph dp_in[dentro do DP]
    otel[plugin OpenTelemetry global]
  end
  dp --- otel
  otel -- OTLP/HTTP protobuf 443 · Basic stack_id:token --> gw[Grafana Cloud OTLP gateway]
  gw --> prom[(Prometheus / Mimir)]
  gw --> loki[(Loki)]
  gw --> tempo[(Tempo)]
  prom & loki & tempo --> graf[Grafana: dashboards · alertas · SLO]
  graf -- HTTPS link público --> boss[Gestão sem login]
```

| # | De → Para | Protocolo / porta | Inicia | Auth | Trafega |
|---|---|---|---|---|---|
| G1 | plugin OTel → OTLP gateway `/otlp/v1/traces` | OTLP/HTTP protobuf, 443 | DP (push) | `Authorization: Basic base64(stack_id:glc_token)` | spans por requisição |
| G2 | plugin OTel → `/otlp/v1/logs` | OTLP/HTTP, 443 | DP | idem | logs de acesso (e prompts, se `log_payloads`) |
| G3 | plugin OTel → `/otlp/v1/metrics` | OTLP/HTTP, 443, a cada 15 s | DP | idem | `http.server.request.count`, `kong.latency.*`, `gen_ai.*` |
| G4 | OTLP gateway → Mimir / Loki / Tempo | interno do Grafana Cloud | Grafana | — | converte para Prometheus (`job="kong"`), Loki e Tempo |
| G5 | Grafana → Mimir / Loki / Tempo | interno | Grafana | — | consultas dos painéis |
| G6 | Navegador → Grafana | HTTPS 443 | usuário | login, ou **link público** (sem login) | dashboard |

**Quem fala com quem:** o DP **empurra** para o Grafana. O Grafana nunca chama o Kong. Sem agente e sem porta aberta.

## 1b. Grafana Cloud: pull via Prometheus + Alloy (DP self-hosted)

```mermaid
flowchart LR
  subgraph host[seu host / cluster]
    dp[DP self-hosted] -- :8100/metrics · plugin Prometheus --> alloy[Grafana Alloy]
  end
  dp -- WSS 443 · mTLS --> cp[Konnect CP]
  alloy -- Prometheus remote_write HTTPS 443 · Basic user:token --> prom[(Grafana Cloud Prometheus)]
  prom --> graf[Grafana]
```

| # | De → Para | Protocolo / porta | Inicia | Auth | Trafega |
|---|---|---|---|---|---|
| P1 | Alloy → DP `:8100/metrics` | HTTP, **local** (127.0.0.1 ou rede interna) | **Alloy** (scrape a cada 15 s) | nenhuma; a porta **não** pode ser pública | `kong_http_requests_total`, `kong_request_latency_ms`, `kong_ai_llm_*` |
| P2 | Alloy → Prometheus remote_write `/api/prom/push` | HTTPS 443 | Alloy | `basic_auth` instance_id + token `glc_` | séries |
| P3 | DP → CP | WSS 443 | DP | mTLS (cluster cert/key) | configuração e telemetria |

Funciona só com DP self-hosted. No serverless não existe acesso à porta 8100.

---

## 2. Splunk

### 2A. HTTP Log → HEC (logs, prompts e tudo via SPL)

```mermaid
flowchart LR
  cli[Cliente] --> dp[DP Kong]
  dp --> up[Upstream]
  dp -- plugin HTTP Log · HTTPS 443 · Authorization: Splunk token --> hec[Splunk HEC]
  hec --> idx[(Indexer · index=kong)]
  idx --> ds[Dashboard Studio · alertas SPL]
```

| # | De → Para | Protocolo / porta | Inicia | Auth | Trafega |
|---|---|---|---|---|---|
| S1 | plugin HTTP Log → HEC `/services/collector/raw` | HTTPS 443 (Cloud) ou 8088 (Enterprise) | DP (push, em lotes pela `queue`) | `Authorization: Splunk <HEC token>` | 1 JSON por requisição: status, latências, consumer, rota, IA, payload |
| S2 | HEC → Indexer | interno do Splunk | Splunk | — | eventos `sourcetype=kong:access` |
| S3 | Search Head → Indexer | interno | Splunk | — | buscas SPL dos painéis e alertas |

### 2B. OpenTelemetry → Splunk Observability Cloud (métricas e traces)

```mermaid
flowchart LR
  dp[DP Kong · plugin OTel] -- OTLP/HTTP 443 · X-SF-Token --> ing[ingest.realm.signalfx.com]
  ing --> apm[APM · traces]
  ing --> im[Infrastructure / Metrics]
  apm & im --> o11y[Splunk Observability dashboards · detectors]
```

| # | De → Para | Protocolo | Inicia | Auth | Trafega |
|---|---|---|---|---|---|
| S4 | plugin OTel → `/v2/trace/otlp` | OTLP/HTTP 443 | DP | `X-SF-Token` (ingest) | spans |
| S5 | plugin OTel → `/v2/datapoint/otlp` | OTLP/HTTP 443 | DP | `X-SF-Token` | métricas |
| — | logs | ❌ não suportado por esse caminho | — | — | use o 2A junto |

### 2C. OpenTelemetry → Splunk OTel Collector → Platform + Observability

```mermaid
flowchart LR
  dp[DP Kong · plugin OTel] -- OTLP/HTTP 4318 sobre TLS público --> col[Splunk OTel Collector]
  col -- HEC 443 · Splunk token --> plat[(Splunk Platform · logs)]
  col -- 443 · X-SF-Token --> obs[(Splunk Observability · métricas e traces)]
```

| # | De → Para | Protocolo | Inicia | Auth | Trafega |
|---|---|---|---|---|---|
| S6 | plugin OTel → Collector `:4318/v1/*` | OTLP/HTTP, **precisa de URL pública com TLS** se o DP for serverless | DP | header que você definir (ex.: bearer) e validar no collector | traces, logs e métricas |
| S7 | Collector → HEC | HTTPS 443 | Collector | HEC token | logs |
| S8 | Collector → Observability ingest | HTTPS 443 | Collector | `X-SF-Token` | métricas e traces |

---

## 3. Looker Studio

O Looker Studio **só lê de armazenamento**. Sempre existe uma peça no meio.

### 3A. HTTP Log → Cloud Run → BigQuery (produção)

```mermaid
flowchart LR
  dp[DP Kong · plugin HTTP Log] -- HTTPS 443 · X-Ingest-Secret · lotes JSON --> fn[Cloud Run function kong-ingest]
  fn -- BigQuery streaming insert · service account --> bq[(BigQuery kong.requests)]
  ls[Looker Studio] -- conector BigQuery · OAuth do dono ou SA --> bq
  boss[Gestão] -- HTTPS link / PDF agendado --> ls
```

| # | De → Para | Protocolo | Inicia | Auth | Trafega |
|---|---|---|---|---|---|
| L1 | plugin HTTP Log → Cloud Run | HTTPS 443 | DP (push em lotes) | header secreto `X-Ingest-Secret` (ou IAM com ID token, mais seguro) | array JSON de eventos |
| L2 | Cloud Run → BigQuery | Google API (gRPC/HTTPS) | function | service account da function (`roles/bigquery.dataEditor`) | linhas |
| L3 | Looker Studio → BigQuery | Google API | Looker (cada abertura ou refresh do cache) | credenciais do dono da fonte (ou service account) | consultas SQL |
| L4 | Navegador → Looker Studio | HTTPS | usuário | conta Google ou link público | relatório |

### 3B. HTTP Log → Apps Script → Google Sheets (hack / demo)

```mermaid
flowchart LR
  dp[DP Kong · plugin HTTP Log] -- HTTPS 443 · ?s=segredo --> gas[Apps Script Web App doPost]
  gas -- SpreadsheetApp --> sh[(Google Sheets requests)]
  ls[Looker Studio] -- conector Sheets --> sh
```

| # | De → Para | Protocolo | Inicia | Auth | Trafega |
|---|---|---|---|---|---|
| L5 | plugin HTTP Log → `script.google.com/macros/s/…/exec` | HTTPS 443 (responde 302) | DP | segredo na query string | lotes JSON |
| L6 | Apps Script → Sheets | interno do Google | script (roda como o dono) | conta do dono | linhas |
| L7 | Looker Studio → Sheets | Google API | Looker | conta do dono | leitura |

### 3C. API do Konnect → job agendado → BigQuery/Sheets (agregados)

```mermaid
flowchart LR
  cron[Job agendado · GitHub Actions / Cloud Scheduler] -- HTTPS 443 · Bearer kpat_ ou spat_ --> api[Konnect Analytics API]
  cron -- Google API --> bq[(BigQuery / Sheets)]
  ls[Looker Studio] --> bq
```

| # | De → Para | Protocolo | Inicia | Auth | Trafega |
|---|---|---|---|---|---|
| L8 | Job → Konnect Analytics API | HTTPS 443 | job (ex.: a cada 15 min) | System Access Token (`spat_`) | agregados (reqs, latência, status por rota) |
| L9 | Job → BigQuery/Sheets | Google API | job | service account | linhas agregadas |

Não toca no gateway: não precisa de plugin, e é o caminho com menos dado sensível.

---

## Comparativo rápido

| Caso | Peças além do Kong | Quem inicia a conexão | Dado por requisição | Prompts | Tempo real |
|---|---|---|---|---|---|
| 1 Grafana OTel | nenhuma | DP → Grafana | ✅ | ✅ (Loki) | ✅ ~15 s |
| 1b Grafana Alloy | Alloy | Alloy → DP (scrape) e Alloy → Grafana | métricas agregadas | ❌ | ✅ ~15 s |
| 2A Splunk HEC | nenhuma | DP → Splunk | ✅ | ✅ | ✅ segundos |
| 2B Splunk O11y | nenhuma | DP → Splunk | métricas e traces | ❌ | ✅ |
| 2C Splunk Collector | Collector | DP → Collector → Splunk | ✅ | ✅ | ✅ |
| 3A Looker BigQuery | Cloud Run + BigQuery | DP → Cloud Run → BQ ← Looker | ✅ | ✅ (mascarado) | ~1 min (cache do Looker) |
| 3B Looker Sheets | Apps Script + Sheets | DP → Apps Script → Sheets ← Looker | ✅ (pouco volume) | ⚠️ não recomendado | minutos |
| 3C Looker agregados | job + BQ/Sheets | job → Konnect, job → BQ ← Looker | ❌ (agregado) | ❌ | 15 min+ |

### Regras de rede que valem para todos

- O **DP só faz conexões de saída** (443) para o CP, os upstreams e o destino de observabilidade. Nenhum destino precisa alcançar o DP, **exceto** o scrape do Alloy (1b), que deve ficar na rede interna.
- No DP **serverless**, todo destino tem que ser **público, com TLS e certificado válido** (o `ssl_verify` fica ligado).
- Segredos dos destinos (token OTLP, HEC, segredo de ingest) devem ficar num **Vault do Konnect** e ser referenciados como `{vault://…}` na configuração do plugin.
