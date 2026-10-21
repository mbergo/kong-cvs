# Kong → Looker Studio (passo a passo)

O Looker Studio **não recebe dados em tempo real**: ele só lê de uma fonte (BigQuery, Google Sheets, Postgres, CSV etc.). Por isso, o caminho é sempre **Kong → um armazenamento → Looker Studio**.

| | A. HTTP Log → Cloud Run → BigQuery | B. HTTP Log → Apps Script → Google Sheets (hack) | C. API do Konnect → BigQuery/Sheets (agendado) |
|---|---|---|---|
| Granularidade | por requisição | por requisição | agregado (por minuto/hora) |
| Volume | milhões/dia | ~poucos milhares/dia (cota do Apps Script) | pequeno |
| Infra | 1 Cloud Run function | nenhuma (só uma conta Google) | 1 job agendado |
| Custo | centavos/dia | grátis | grátis |
| Para | produção | demo e protótipo | relatório executivo |

---

## Opção A: BigQuery (recomendada)

### 1. Tabela no BigQuery

```sql
CREATE TABLE `PROJ.kong.requests` (
  ts TIMESTAMP, route STRING, service STRING, consumer STRING, method STRING, status INT64,
  latency_ms INT64, kong_ms INT64, upstream_ms INT64, req_bytes INT64, resp_bytes INT64, client_ip STRING,
  ai_model STRING, ai_provider STRING, prompt_tokens INT64, completion_tokens INT64, ai_cost FLOAT64,
  prompt STRING  -- só se log_payloads estiver ligado e o conteúdo for mascarado
) PARTITION BY DATE(ts) CLUSTER BY route, consumer;
```

### 2. Receptor (Cloud Run function, Python)

```python
# main.py — gcloud functions deploy kong-ingest --gen2 --runtime python312 --trigger-http --allow-unauthenticated
import os, functions_framework
from google.cloud import bigquery
bq, TABLE, SECRET = bigquery.Client(), os.environ["TABLE"], os.environ["INGEST_SECRET"]

def row(e):
    ai = (e.get("ai") or {}).get("proxy") or {}
    u, m = ai.get("usage") or {}, ai.get("meta") or {}
    lat = e.get("latencies") or {}
    return {"ts": e["started_at"] / 1000, "route": (e.get("route") or {}).get("name"),
            "service": (e.get("service") or {}).get("name"), "consumer": (e.get("consumer") or {}).get("username"),
            "method": e["request"]["method"], "status": e["response"]["status"],
            "latency_ms": lat.get("request"), "kong_ms": lat.get("kong"), "upstream_ms": lat.get("proxy"),
            "req_bytes": e["request"].get("size"), "resp_bytes": e["response"].get("size"), "client_ip": e.get("client_ip"),
            "ai_model": m.get("request_model"), "ai_provider": m.get("provider_name"),
            "prompt_tokens": u.get("prompt_tokens"), "completion_tokens": u.get("completion_tokens"), "ai_cost": u.get("cost"),
            "prompt": str((ai.get("payload") or {}).get("request"))[:10000] if ai.get("payload") else None}

@functions_framework.http
def ingest(req):
    if req.headers.get("X-Ingest-Secret") != SECRET:
        return ("forbidden", 403)
    body = req.get_json(silent=True)
    events = body if isinstance(body, list) else [body]
    errors = bq.insert_rows_json(TABLE, [row(e) for e in events if e])
    return ("ok", 200) if not errors else (str(errors), 500)
```

Variáveis: `TABLE=PROJ.kong.requests`, `INGEST_SECRET=<aleatório>`.

### 3. Kong: plugin HTTP Log global

```yaml
plugins:
  - name: http-log
    config:
      http_endpoint: https://<região>-<proj>.cloudfunctions.net/kong-ingest
      method: POST
      content_type: application/json
      headers: { X-Ingest-Secret: <INGEST_SECRET> }
      queue: { max_batch_size: 200, max_coalescing_delay: 5 }   # array de até 200 eventos por POST
```

### 4. Looker Studio

1. lookerstudio.google.com → **Create → Data source → BigQuery** → `PROJ.kong.requests`.
2. Campos calculados:
   - `Success` = `IF(status < 400, 1, 0)`; **Success rate** = `AVG(Success)` (formato %)
   - `Status class` = `CONCAT(SUBSTR(CAST(status AS TEXT),1,1),"xx")`
   - `Blocked` = `IF(status IN (401,403,429), 1, 0)`
   - `Total tokens` = `prompt_tokens + completion_tokens`
3. Para p95, crie uma **Custom Query** no BigQuery como segunda fonte:
   ```sql
   SELECT TIMESTAMP_TRUNC(ts, MINUTE) minute, route,
          APPROX_QUANTILES(latency_ms, 100)[OFFSET(95)] p95_ms, COUNT(*) reqs
   FROM `PROJ.kong.requests` WHERE ts > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
   GROUP BY 1, 2
   ```
4. Componentes do relatório:

| Componente | Configuração |
|---|---|
| **Scorecard** (×4) | Requisições, Success rate (%), p95 (custom query), Bloqueados, cada um com comparação ao período anterior |
| **Gauge** | Success rate, faixas: vermelho < 85%, laranja < 95%, verde |
| **Time series** | Record Count por minuto, breakdown `Status class` (empilhado) |
| **Line** | p95 por rota (custom query) |
| **Bar (horizontal)** | Top rotas e top consumers |
| **Donut** | `Status class` |
| **Table com heatmap** | rota × (reqs, % erro, p95), com *conditional formatting* |
| **Geo map** | `client_ip` → crie um campo de país no BigQuery (tabela `GeoLite2`) |
| **Pivot table** | consumer × rota × status |
| **Treemap** | tokens por modelo e consumer (IA) |
| **Controles** | Date range, drop-down de rota, consumer e status |

5. **Atualização**: o BigQuery é lido em tempo real, mas o cache de dados do Looker deve ficar em **1 minuto** (Data freshness).
6. **Compartilhar**: Share → link "Anyone with the link can view". Para o chefe, pode agendar um **PDF por e-mail** (Schedule email delivery).

---

## Opção B (hack): Google Sheets via Apps Script, sem infraestrutura

1. Crie uma planilha com a aba `requests` e o cabeçalho: `ts, route, consumer, method, status, latency_ms, kong_ms, upstream_ms, resp_bytes`.
2. Extensions → **Apps Script**:

```javascript
const SECRET = 'troque-isto';
function doPost(e) {
  if ((e.parameter.s || '') !== SECRET) return ContentService.createTextOutput('forbidden');
  const body = JSON.parse(e.postData.contents);
  const evs = Array.isArray(body) ? body : [body];
  const rows = evs.map(x => [new Date(x.started_at), x.route && x.route.name, x.consumer && x.consumer.username,
    x.request.method, x.response.status, x.latencies.request, x.latencies.kong, x.latencies.proxy, x.response.size]);
  const sh = SpreadsheetApp.getActive().getSheetByName('requests');
  sh.getRange(sh.getLastRow() + 1, 1, rows.length, rows[0].length).setValues(rows);
  return ContentService.createTextOutput('ok');
}
```

3. **Deploy → New deployment → Web app** → Execute as *Me*, Access *Anyone*. Copie a URL `https://script.google.com/macros/s/…/exec`.
4. No Kong, use o HTTP Log com `http_endpoint: https://script.google.com/macros/s/…/exec?s=troque-isto` e `queue.max_batch_size: 500`, `max_coalescing_delay: 30`. Lotes grandes economizam a cota.
5. No Looker Studio: **Google Sheets** connector → a planilha → mesmos campos calculados da Opção A.

> Limites: cerca de 20 mil chamadas por dia no Apps Script e 10 milhões de células por planilha. Serve para demo. Para não estourar, rode um gatilho diário que apaga as linhas com mais de 7 dias.
> O Apps Script responde com redirect 302: o HTTP Log trata isso como sucesso, então ignore os avisos.

---

## Opção C: agregados do Konnect, sem plugin

O Konnect já mede tudo (Analytics). Um job agendado puxa os agregados e grava no BigQuery ou no Sheets:

```bash
# Explorer API (Konnect Analytics) — requisições por rota e status, por hora
curl -s -X POST https://us.api.konghq.com/v2/api-requests \
  -H "Authorization: Bearer $KONNECT_TOKEN" -H 'Content-Type: application/json' \
  -d '{"time_range":{"type":"relative","time_range":"24h"}}'
```

Rode com GitHub Actions (`schedule: cron '*/15 * * * *'`), Cloud Scheduler ou cron, e grave com `bq insert` ou com a API do Sheets. Bom para o **relatório executivo** (tendência diária e semanal), sem expor dado por requisição.

> Confirme o endpoint e o formato no portal de API do Konnect (Analytics/Explorer), porque eles mudam entre versões.

---

## Hacks extras

- **Grafana → Looker:** o Looker Studio lê **CSV/JSON por URL** pelos connectors de parceiros (ex.: "JSON/CSV/XML"). Uma Cloud Function que consulta a API Prometheus do Grafana Cloud (token com `metrics:read`) e devolve CSV reaproveita os dados do OTel sem novo plugin.
- **Prompts no Looker:** só pela Opção A, com a coluna `prompt` e o **AI Sanitizer** antes. Em saúde, prefira guardar só `prompt_tokens` e um hash do prompt.
- **Teste sem tráfego real:** `make traffic` gera tráfego variado (7 rotas, 5 consumers, 2xx/4xx/5xx, latência e payloads).
