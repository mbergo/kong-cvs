# Kong → Splunk (passo a passo)

Três caminhos, do mais simples ao mais completo. Para a maioria dos casos, a **Opção A** basta.

| | A. HTTP Log → HEC | B. OTel → Splunk Observability Cloud | C. OTel → Collector → Splunk (tudo) |
|---|---|---|---|
| Infra extra | nenhuma | nenhuma | 1 container (Splunk OTel Collector) |
| Logs de acesso e prompts | ✅ | ❌ | ✅ |
| Métricas e traces | derivados dos logs (SPL) | ✅ nativos | ✅ |
| Produto Splunk | Enterprise / Cloud Platform | Observability Cloud | os dois |

---

## Opção A: HTTP Log → Splunk HEC (sem infraestrutura)

### 1. Splunk: criar o HEC

1. Settings → Data inputs → **HTTP Event Collector** → Global Settings → **Enabled**.
2. **New Token**: nome `kong`, sourcetype `_json` (ou crie `kong:access`), index `kong` (crie o index antes).
3. Copie o token. A URL é:
   - Splunk Cloud: `https://http-inputs-<stack>.splunkcloud.com/services/collector/raw`
   - Enterprise: `https://<host>:8088/services/collector/raw`

### 2. Kong: plugin HTTP Log global

```yaml
# decK (kong/kong-cloud.yaml) — ou Konnect → Plugins → HTTP Log → Global
plugins:
  - name: http-log
    config:
      http_endpoint: https://http-inputs-<stack>.splunkcloud.com/services/collector/raw?sourcetype=kong:access&index=kong
      method: POST
      content_type: application/json
      headers:
        Authorization: Splunk <HEC_TOKEN>   # melhor: {vault://env/splunk-hec}
      queue:
        max_batch_size: 1                   # 1 evento por POST: o /raw não precisa quebrar array
        max_coalescing_delay: 1
      custom_fields_by_lua:                 # campos extras planos (opcional)
        env: "return 'prod'"
```

> **Hack de volume:** com `max_batch_size > 1`, o Kong manda um **array JSON**. No `/raw`, defina no `props.conf` do sourcetype `LINE_BREAKER = ([\r\n,]*)\{"latencies"` e `SHOULD_LINEMERGE=false`, ou mande para `/services/collector/event` usando um `custom_fields_by_lua` que envolva o evento. Com batch 1, tudo funciona sem configuração.

### 3. Campos que chegam (por requisição)

`request.method`, `request.uri`, `request.headers.*`, `response.status`, `response.size`, `latencies.request`, `latencies.kong`, `latencies.proxy`, `service.name`, `route.name`, `consumer.username`, `client_ip`, `started_at`, `upstream_uri`.

Em rotas de IA, com o AI Proxy `logging.log_statistics: true`, chegam também: `ai.proxy.usage.prompt_tokens`, `ai.proxy.usage.completion_tokens`, `ai.proxy.usage.cost`, `ai.proxy.meta.request_model`, `ai.proxy.meta.provider_name`. Com `log_payloads: true`, chega o `ai.proxy.payload.request` (**o prompt**) e o `.response`.

> Antes de ligar `log_payloads`, use o **AI Sanitizer** ou um mascaramento no Splunk (`SEDCMD` no `props.conf`). Em saúde, isso é obrigatório.

### 4. Dashboard (Dashboard Studio): buscas SPL

| Painel | Visualização | SPL |
|---|---|---|
| Requisições/min | Single value + sparkline | `index=kong \| timechart span=1m count` |
| Taxa de sucesso | Gauge (radial) | `index=kong \| eval ok=if('response.status'<400,1,0) \| stats avg(ok) as success \| eval success=round(success*100,2)` |
| Latência p95 | Gauge | `index=kong \| stats perc95(latencies.request) as p95_ms` |
| Tráfego por classe de status | Column (stacked) | `index=kong \| eval class=substr('response.status',1,1)."xx" \| timechart span=1m count by class` |
| Latência p50/p95/p99 | Line | `index=kong \| timechart span=1m perc50(latencies.request) perc95(latencies.request) perc99(latencies.request)` |
| Kong vs upstream | Area (stacked) | `index=kong \| timechart span=1m avg(latencies.kong) as kong avg(latencies.proxy) as upstream` |
| Top consumers | Bar | `index=kong \| top limit=10 consumer.username` |
| Top rotas | Bar | `index=kong \| top limit=10 route.name` |
| Mix de status | Pie | `index=kong \| stats count by response.status` |
| Saúde por rota | Table + cores | `index=kong \| stats count, avg(eval(if('response.status'>=400,1,0))) as err, perc95(latencies.request) as p95 by route.name` |
| Bloqueados (401/403/429) | Single value | `index=kong response.status IN (401,403,429) \| stats count` |
| Mapa de clientes | Choropleth | `index=kong \| iplocation client_ip \| geostats count by Country` |
| Tokens de IA por modelo | Column | `index=kong ai.proxy.usage.total_tokens=* \| timechart sum(ai.proxy.usage.total_tokens) by ai.proxy.meta.request_model` |
| Custo de IA | Single value (US$) | `index=kong \| stats sum(ai.proxy.usage.cost) as usd` |
| Prompts (auditoria) | Events/Table | `index=kong ai.proxy.payload.request=* \| table _time consumer.username route.name ai.proxy.payload.request` |

Alertas: `Saved search` a cada 5 min, por exemplo `index=kong earliest=-5m | stats avg(eval('response.status'>=500)) as e | where e>0.05`.

---

## Opção B: OTel direto para o Splunk Observability Cloud

O Splunk Observability Cloud (ex-SignalFx) aceita OTLP/HTTP direto, então dá para usar o **mesmo plugin OpenTelemetry**, só trocando o destino:

```yaml
- name: opentelemetry
  config:
    traces_endpoint: https://ingest.<realm>.signalfx.com/v2/trace/otlp
    metrics:
      endpoint: https://ingest.<realm>.signalfx.com/v2/datapoint/otlp
      enable_request_metrics: true
      enable_latency_metrics: true
      enable_bandwidth_metrics: true
      enable_consumer_attribute: true
      enable_ai_metrics: true
    headers:
      X-SF-Token: <ACCESS_TOKEN_INGEST>
```

- `realm`: `us0`, `us1`, `eu0` e assim por diante (Settings → Organization).
- O APM mostra o serviço `kong` com mapa, RED e traces. As métricas `http.server.request.count`, `kong.latency.*` e `gen_ai.*` aparecem no Metric Finder para montar os charts.
- **Logs não vão por esse caminho.** Para logs e prompts, junte com a Opção A.

---

## Opção C: OTel → Splunk OTel Collector → Splunk Platform + Observability

Use quando quiser **um único plugin** (OTel) mandando para os dois produtos.

```yaml
# collector.yaml (imagem quay.io/signalfx/splunk-otel-collector)
receivers:
  otlp: { protocols: { http: { endpoint: 0.0.0.0:4318 } } }
exporters:
  splunk_hec/logs:
    token: ${SPLUNK_HEC_TOKEN}
    endpoint: https://http-inputs-<stack>.splunkcloud.com/services/collector
    index: kong
    sourcetype: kong:otel
  signalfx:   { access_token: ${SPLUNK_ACCESS_TOKEN}, realm: us1 }
  otlphttp/apm: { traces_endpoint: https://ingest.us1.signalfx.com/v2/trace/otlp, headers: { X-SF-Token: ${SPLUNK_ACCESS_TOKEN} } }
service:
  pipelines:
    logs:    { receivers: [otlp], exporters: [splunk_hec/logs] }
    metrics: { receivers: [otlp], exporters: [signalfx] }
    traces:  { receivers: [otlp], exporters: [otlphttp/apm] }
```

No Kong, o plugin OTel aponta para `http://<collector>:4318/v1/{traces,logs,metrics}`. O collector pode rodar no Coolify, no ECS ou numa VM. Com Kong Cloud (serverless), ele precisa de **URL pública com TLS**.

---

## Hacks úteis

- **Sem acesso para criar HEC?** Use o **Splunk Universal Forwarder** lendo um arquivo: o `file-log` do Kong só serve em data plane self-hosted. No serverless, use a Opção A.
- **Reaproveitar o que já está no Grafana:** o Grafana Cloud tem um **data source Splunk** (plugin Enterprise), que permite um dashboard único misturando Prometheus e Splunk.
- **Menos custo de ingestão:** `queue.max_batch_size` maior, sourcetype com `TRUNCATE` e `custom_fields_by_lua` removendo headers grandes (`kong.log.set_serialize_value("request.headers", nil)`).
- **Gerar tráfego para testar:** `make traffic`, que já cobre 7 rotas, 5 consumers e erros variados.
