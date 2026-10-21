# kong-cvs — Kong Cloud + Grafana Cloud, do zero

Kong Gateway no **Kong Cloud (Konnect, serverless)**, com tráfego de demonstração e observabilidade completa no **Grafana Cloud** via OpenTelemetry. Tudo por CLI e versionado.

```
cliente ──► Kong Cloud (serverless) ──► httpbin (upstreams de demo)
                 │ plugin OpenTelemetry (global)
                 ▼
          Grafana Cloud OTLP ──► Prometheus (métricas) · Loki (logs) · Tempo (traces)
                                        │
                                        ▼
                           Dashboard "Kong Cloud — Command Center"
```

## O que você precisa

| Ferramenta | Instalação |
|---|---|
| `deck` (CLI da Kong) | `brew install kong/deck/deck` |
| `jq`, `curl`, `openssl`, `make` | gerenciador de pacotes do sistema |
| `docker` | para o gerador de tráfego |
| Conta **Kong Konnect** | cloud.konghq.com (o trial serve) |
| Conta **Grafana Cloud** | grafana.com (o trial serve) |

## Passo a passo

### 1. Clonar

```bash
git clone https://github.com/mbergo/kong-cvs ~/github/kong-cvs
cd ~/github/kong-cvs
mkdir -p secrets && chmod 700 secrets   # secrets/ fica fora do git
```

### 2. Control plane serverless no Konnect

1. Konnect → **API Gateway → Control planes → New** → **Serverless**. Nome: `serverless-api-gateway-demo`.
2. Anote a **Proxy URL** (ex.: `https://3fb7c42224.us.serverless.gateways.konggateway.com`).
3. Avatar → **Personal Access Tokens → Generate token** (na mesma organização do control plane):

```bash
echo 'KONNECT_TOKEN=kpat_...' > secrets/konnect.env
echo 'KONG_SERVERLESS_URL=https://<sua-proxy-url>' > secrets/tester.env
chmod 600 secrets/*.env
```

### 3. Credenciais do Grafana Cloud (OTLP)

1. Grafana Cloud → **Connections → Add new connection → OpenTelemetry (OTLP)** → **Minimal setup**.
2. Crie um token. Ele precisa dos escopos `metrics:write`, `logs:write` e `traces:write`.
3. A tela mostra `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic%20<valor>`. Pegue o `<valor>`:

```bash
echo 'GRAFANA_OTLP_AUTH_HEADER=Basic <valor>' > secrets/grafana-otlp.env   # espaço normal, sem %20, sem aspas
chmod 600 secrets/grafana-otlp.env
```

> Ajuste a região do endpoint em `kong/kong-cloud.yaml` se o seu stack não for `prod-us-east-3`.

### 4. Subir tudo no Kong Cloud

```bash
make cloud-diff   # mostra o que vai mudar
make cloud        # aplica kong/kong-cloud.yaml, testa as rotas e inicia o gerador de tráfego
```

O que é criado (`kong/kong-cloud.yaml`):

| Item | Detalhe |
|---|---|
| Plugin global **OpenTelemetry** | traces, logs e métricas (incluindo AI) → Grafana Cloud |
| 7 APIs | `/test` (Kong-Bro), `/orders`, `/payments`, `/users`, `/catalog`, `/search`, `/legacy` |
| Key auth | em todas as APIs (header `apikey`) |
| Rate limiting | `/search`: 40 req/min, gera 429 |
| Request termination | `/legacy`: sempre 503 |
| 5 consumers | `bro`, `web-app`, `mobile-app`, `partner-acme`, `internal-batch`; chaves geradas em `secrets/demo-consumers.env` |

Teste manual:

```bash
source secrets/tester.env secrets/demo-consumers.env
curl -i "$KONG_SERVERLESS_URL/orders/get"                          # 401
curl -i -H "apikey: $KEY_WEB_APP" "$KONG_SERVERLESS_URL/orders/get"  # 200
```

### 5. Gerador de tráfego

```bash
make traffic        # container kong-traffic, roda sem parar (restart unless-stopped)
make traffic-logs   # status
make traffic-stop   # parar
```

Ele mistura 7 rotas, 5 consumers e chamadas anônimas, com GET, POST, PUT e DELETE, respostas 2xx/4xx/5xx, latência (`/delay`), payloads de vários tamanhos (`/bytes`) e rajadas no `/search` que estouram o rate limit.

### 6. Dashboard no Grafana

**Opção A: import (30 segundos)**
Grafana → **Dashboards → New → Import** → cole:
```
https://raw.githubusercontent.com/mbergo/kong-cvs/main/dashboards/kong-command-center.json
```
→ escolha o data source `grafanacloud-<stack>-prom` → **Import**.

**Opção B: automático por API**

1. Grafana → **Administration → Users and access → Service accounts → Add**, role **Editor** → **Add token**.
2. Salve e rode:

```bash
printf 'GRAFANA_URL=https://<stack>.grafana.net\nGRAFANA_API_TOKEN=glsa_...\n' > secrets/grafana-api.env
chmod 600 secrets/grafana-api.env
make dashboards   # pasta "Kong" + Command Center + dashboard oficial 7424 + link público
```

**Opção C: pelo Grafana Assistant**
Abra o **Assistant** no Grafana e cole o conteúdo de [`dashboards/GRAFANA_ASSISTANT_PROMPT.md`](dashboards/GRAFANA_ASSISTANT_PROMPT.md).

### 7. Compartilhar com quem não tem login

No dashboard: **Share → Share externally → Public dashboard** → copie o link.
(Dashboards públicos não aceitam variáveis. O Command Center não usa nenhuma, então funciona.)

## O dashboard

**Kong Cloud — Command Center** (`dashboards/kong-command-center.json`, gerado por `dashboards/gen_command_center.py`), com 27 painéis de 13 tipos:

| Seção | Componentes |
|---|---|
| KPIs | stat (req/min, bloqueadas, consumers ativos) · gauge (taxa de sucesso, latência p95, 5xx) |
| Tráfego | barras empilhadas por classe de status · linhas p50/p95/p99 |
| Quem e o quê | bar chart por rota · bar gauge top consumers · donut do mix de status |
| Saúde no tempo | state timeline (gateway) · status history (erro por rota) · stats por rota |
| Latência | heatmap · histogram (p95 por rota) · gateway vs upstream |
| Rotas | tabela de saúde por rota (req/s, % erro, p95) · banda · métodos · 429/min |

Métricas usadas (OTel do Kong, como o Prometheus do Grafana Cloud as nomeia):
`http_server_request_count_total`, `kong_latency_{total,upstream,internal}_seconds_bucket`, `http_server_{request,response}_size_bytes_sum`; labels `http_response_status_code`, `http_request_method`, `kong_route_name`, `kong_service_name`, `kong_auth_consumer_name`, `job="kong"`.

## Data plane self-hosted (opcional)

Para rodar um data plane próprio (ex.: o AI Gateway `ai-gw-kong`) e coletar `:8100/metrics` com o Grafana Alloy, veja o [`RUNBOOK.md`](RUNBOOK.md), passos 01–06 (`make up`, `make alloy-up`).

## Comandos

```bash
make help
```

| Comando | O que faz |
|---|---|
| `make cloud` / `make cloud-diff` | aplica ou compara `kong/kong-cloud.yaml` no Kong Cloud |
| `make traffic` / `traffic-stop` / `traffic-logs` | gerador de tráfego |
| `make dashboards` | publica os dashboards no Grafana e gera o link público |
| `make up` / `down` / `status` / `logs` / `check` | data plane self-hosted |
| `make alloy-up` / `alloy-down` / `alloy-logs` | Alloy (self-hosted → Grafana) |

## Segurança

- Tudo que é segredo fica em `secrets/`, que está no `.gitignore`. Nada sensível é commitado.
- `KONG_TLS_CERTIFICATE_VERIFY=off` em `config.env` é **só para teste**. Em produção, mantenha `on`.
- As chaves de consumer de demo são geradas localmente (`openssl rand`) e enviadas ao Konnect pelo decK.
