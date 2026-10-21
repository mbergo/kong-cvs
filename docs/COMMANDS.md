# Comandos de exemplo: cada conexão na mão

Um comando por conexão do [`ARCHITECTURE.md`](ARCHITECTURE.md) (os números batem: 1–5, G1–G6, P1–P3, S1–S8, L1–L9).
Os valores em `<…>` você troca. Os segredos vêm dos `secrets/*.env`.

```bash
cd ~/github/kong-cvs
source secrets/konnect.env; source secrets/tester.env; source secrets/demo-consumers.env; source secrets/grafana-otlp.env
P=$KONG_SERVERLESS_URL                       # proxy do DP serverless
K=https://us.api.konghq.com                  # Konnect API (região us)
CP=$(curl -s -H "Authorization: Bearer $KONNECT_TOKEN" "$K/v2/control-planes?filter%5Bname%5D%5Beq%5D=serverless-api-gateway-demo" | jq -r '.data[0].id')
```

## Base (todos os casos)

```bash
# 1 · decK → Control plane: ver diferença e aplicar
deck gateway diff --konnect-token "$KONNECT_TOKEN" --konnect-addr $K kong/kong-cloud.yaml
deck gateway sync --konnect-token "$KONNECT_TOKEN" --konnect-addr $K kong/kong-cloud.yaml
deck gateway dump --konnect-token "$KONNECT_TOKEN" --konnect-addr $K --konnect-control-plane-name serverless-api-gateway-demo -o atual.yaml

# 1 · mesma coisa pela API: listar rotas e plugins
curl -s -H "Authorization: Bearer $KONNECT_TOKEN" "$K/v2/control-planes/$CP/core-entities/routes"  | jq -r '.data[].name'
curl -s -H "Authorization: Bearer $KONNECT_TOKEN" "$K/v2/control-planes/$CP/core-entities/plugins" | jq -r '.data[] | "\(.name)  service=\(.service.id // "-") route=\(.route.id // "-")"'

# 2 · DP ↔ CP: status dos nós (sync)
curl -s -H "Authorization: Bearer $KONNECT_TOKEN" "$K/v2/control-planes/$CP/nodes" | jq -r '.items[] | "\(.hostname) \(.version) last_ping=\(.last_ping)"'
#   DP self-hosted: o próprio log mostra a conexão
sudo docker logs kong-dp 2>&1 | grep -E 'sync v2 is enabled in CP|error'

# 3 · Cliente → DP
curl -i  "$P/orders/get"                                   # 401: sem chave
curl -i  -H "apikey: $KEY_WEB_APP" "$P/orders/get"         # 200
curl -i  -H "apikey: $KEY_WEB_APP" "$P/legacy/get"         # 503 (request-termination)
for i in $(seq 60); do curl -s -o /dev/null -w '%{http_code} ' -H "apikey: $KEY_WEB_APP" "$P/search/get"; done; echo   # 429 a partir de 40/min

# 4 · DP → Upstream: cabeçalhos que o Kong devolve
curl -s -D - -o /dev/null -H "apikey: $KEY_WEB_APP" "$P/orders/get" | grep -iE 'x-kong-(upstream|proxy)-latency|via'
curl -s -H "apikey: $KEY_WEB_APP" "$P/orders/get" | jq '.headers | with_entries(select(.key|test("Consumer";"i")))'   # consumer que o upstream viu
```

## 1 · Grafana Cloud via OpenTelemetry

```bash
# G1–G3 · simular o DP mandando OTLP (testa endpoint + auth sem precisar do Kong)
O=https://otlp-gateway-prod-us-east-3.grafana.net/otlp
curl -s -o /dev/null -w 'traces  %{http_code}\n' -H "Authorization: $GRAFANA_OTLP_AUTH_HEADER" -H 'Content-Type: application/json' -d '{"resourceSpans":[]}'   $O/v1/traces
curl -s -o /dev/null -w 'logs    %{http_code}\n' -H "Authorization: $GRAFANA_OTLP_AUTH_HEADER" -H 'Content-Type: application/json' -d '{"resourceLogs":[]}'    $O/v1/logs
curl -s -o /dev/null -w 'metrics %{http_code}\n' -H "Authorization: $GRAFANA_OTLP_AUTH_HEADER" -H 'Content-Type: application/json' -d '{"resourceMetrics":[]}' $O/v1/metrics
#   200 = ok · 401 = header errado (espaço, %20, aspas, stack id) · 404 = região/path errados

# G1–G3 · gerar tráfego real para o plugin emitir
make traffic            # ou: for i in $(seq 100); do curl -s -o /dev/null -H "apikey: $KEY_WEB_APP" $P/orders/get; done

# G5 · ler o que chegou (token de leitura: service account glsa_ ou glc_ com metrics:read)
G=https://orangestream1692.grafana.net
curl -s -H "Authorization: Bearer <glsa_token>" "$G/api/datasources/proxy/uid/grafanacloud-prom/api/v1/query" \
  --data-urlencode 'query=sum by (http_response_status_code) (rate(http_server_request_count_total{job="kong"}[5m]))' | jq '.data.result'
curl -s -H "Authorization: Bearer <glsa_token>" "$G/api/datasources/proxy/uid/grafanacloud-logs/loki/api/v1/query_range" \
  --data-urlencode 'query={service_name="kong"}' --data-urlencode 'limit=5' | jq '.data.result[].values[][1]' | head

# G6 · dashboard público: consulta um painel sem login (o mesmo que o navegador faz)
T=<access_token_do_link_publico>
curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"timeRange\":{\"from\":\"$(($(date +%s)-3600))000\",\"to\":\"$(date +%s)000\"}}" \
  "$G/api/public/dashboards/$T/panels/1/query" | jq '.results.A.frames[0].data.values'

# publicar/atualizar o dashboard por API
make dashboards         # usa secrets/grafana-api.env
```

## 1b · Grafana via Alloy (DP self-hosted)

```bash
make up && make alloy-up
# P1 · Alloy → DP: o que o Alloy coleta
curl -s 127.0.0.1:8100/metrics | grep -E '^kong_(http_requests_total|control_plane_connected)' | head
curl -s 127.0.0.1:8100/status | jq '.server'
# P2 · Alloy → Grafana: amostras enviadas/falhas
curl -s 127.0.0.1:12345/metrics | grep -E '^prometheus_remote_storage_samples_(total|failed_total)'
# P2 · remote_write na mão (teste de credencial)
source secrets/grafana.env
curl -s -o /dev/null -w '%{http_code}\n' -u "$GRAFANA_PROM_USER:$GRAFANA_PROM_TOKEN" -X POST "$GRAFANA_PROM_URL"   # 400 = auth ok (sem payload) · 401 = auth errada
# P3 · DP → CP
make check
```

## 2 · Splunk

```bash
HEC=https://http-inputs-<stack>.splunkcloud.com      # Enterprise: https://<host>:8088
HEC_TOKEN=<hec_token>

# S1 · simular o HTTP Log do Kong mandando 1 evento
curl -s "$HEC/services/collector/raw?sourcetype=kong:access&index=kong" -H "Authorization: Splunk $HEC_TOKEN" \
  -d '{"request":{"method":"GET","uri":"/orders/get"},"response":{"status":200},"latencies":{"request":42,"kong":2,"proxy":40},"route":{"name":"orders"},"consumer":{"username":"web-app"}}'
# S1 · health do HEC
curl -s "$HEC/services/collector/health"

# S1 · ligar no Kong (decK): adicione ao kong/kong-cloud.yaml e aplique
#   - name: http-log
#     config: { http_endpoint: "<HEC>/services/collector/raw?sourcetype=kong:access&index=kong",
#               headers: { Authorization: "Splunk <HEC_TOKEN>" }, queue: { max_batch_size: 1 } }
make cloud

# S3 · consultar pela API REST do Splunk
curl -s -k -u <user>:<senha> https://<splunk>:8089/services/search/jobs/export \
  -d search='search index=kong earliest=-15m | stats count by response.status' -d output_mode=csv

# S4/S5 · Splunk Observability (OTLP direto): teste de token
curl -s -o /dev/null -w '%{http_code}\n' -X POST "https://ingest.<realm>.signalfx.com/v2/trace/otlp" \
  -H "X-SF-Token: <ingest_token>" -H 'Content-Type: application/x-protobuf' --data-binary ''

# S6–S8 · Collector
docker run -d --name splunk-otel -p 4318:4318 -v $PWD/collector.yaml:/etc/otel/config.yaml \
  -e SPLUNK_HEC_TOKEN=<hec> -e SPLUNK_ACCESS_TOKEN=<o11y> quay.io/signalfx/splunk-otel-collector:latest --config /etc/otel/config.yaml
curl -s -o /dev/null -w '%{http_code}\n' -H 'Content-Type: application/json' -d '{"resourceLogs":[]}' http://localhost:4318/v1/logs   # S6
```

## 3 · Looker Studio

```bash
# L1 · simular o HTTP Log mandando um lote para o Cloud Run
FN=https://<regiao>-<proj>.cloudfunctions.net/kong-ingest
curl -s -X POST $FN -H 'Content-Type: application/json' -H 'X-Ingest-Secret: <segredo>' \
  -d '[{"started_at":'$(date +%s000)',"request":{"method":"GET","size":120},"response":{"status":200,"size":512},"latencies":{"request":42,"kong":2,"proxy":40},"route":{"name":"orders"},"service":{"name":"orders-api"},"consumer":{"username":"web-app"},"client_ip":"1.2.3.4"}]'

# deploy da function
gcloud functions deploy kong-ingest --gen2 --runtime python312 --region us-east1 --source fn/ \
  --entry-point ingest --trigger-http --allow-unauthenticated --set-env-vars TABLE=<proj>.kong.requests,INGEST_SECRET=<segredo>

# L2 · conferir no BigQuery
bq query --use_legacy_sql=false 'SELECT route, COUNT(*) n, APPROX_QUANTILES(latency_ms,100)[OFFSET(95)] p95 FROM `<proj>.kong.requests` WHERE ts > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR) GROUP BY route'

# L5 · hack Sheets: simular o Kong mandando para o Apps Script (segue o redirect)
curl -sL -X POST "https://script.google.com/macros/s/<id>/exec?s=<segredo>" -H 'Content-Type: application/json' \
  -d '[{"started_at":'$(date +%s000)',"request":{"method":"GET"},"response":{"status":200,"size":512},"latencies":{"request":42,"kong":2,"proxy":40},"route":{"name":"orders"},"consumer":{"username":"web-app"}}]'

# L8 · agregados do Konnect (job agendado)
curl -s -X POST "$K/v2/api-requests" -H "Authorization: Bearer $KONNECT_TOKEN" -H 'Content-Type: application/json' \
  -d '{"time_range":{"type":"relative","time_range":"1h"}}' | jq '.results | length'
# L9 · gravar no BigQuery
bq load --source_format=NEWLINE_DELIMITED_JSON <proj>:kong.hourly agregados.ndjson
```

## Atalhos do repo

```bash
make help            # tudo
make cloud           # 1: aplica o Kong Cloud inteiro (decK) + smoke test + tráfego
make cloud-diff      # 1: só mostra a diferença
make traffic         # 3: gerador contínuo  ·  make traffic-stop
make dashboards      # G5/G6: publica no Grafana + link público
make up / alloy-up   # 1b: DP self-hosted + Alloy
make check / metrics # P1/P3
```
