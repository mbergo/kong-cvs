Create a new dashboard "Kong Cloud — Command Center" in folder "Kong", data source grafanacloud-prom (Prometheus), time range last 1h, refresh 30s.

Data: Kong Gateway (Konnect serverless) sends OpenTelemetry metrics, all with job="kong":
- http_server_request_count_total — labels: http_response_status_code, http_request_method, kong_route_name, kong_service_name, kong_auth_consumer_name
- kong_latency_total_seconds_bucket, kong_latency_upstream_seconds_bucket, kong_latency_internal_seconds_bucket — histograms (le), labels kong_route_name, kong_service_name
- http_server_request_size_bytes_sum, http_server_response_size_bytes_sum
Routes: orders, payments, users, catalog, search (rate limited → 429), legacy (always 503), bro-test. Consumers: web-app, mobile-app, partner-acme, internal-batch, bro (+ anonymous 401s).
First verify these metric and label names exist (Explore) and adapt queries if any differ. Use 5m windows for KPIs and $__rate_interval for time series.

Panels (use a different visualization for each):
1. Text header (markdown): "Kong Cloud — Command Center".
2. Stat "Requests / min": sum(rate(http_server_request_count_total{job="kong"}[5m]))*60, background color, sparkline.
3. Gauge "Success rate": 2xx+3xx / all, percentunit 0–1, thresholds red<0.85<orange<0.95<green.
4. Gauge "Latency p95": histogram_quantile(0.95, sum by (le)(rate(kong_latency_total_seconds_bucket{job="kong"}[5m]))), 0–3s.
5. Gauge "5xx errors": 5xx / all, 0–0.25.
6. Stat "Blocked / min": status 401|403|429.
7. Stat "Active consumers": count of consumers with traffic.
8. Time series (stacked bars) "Traffic by status class" 2xx/3xx/4xx/5xx colored green/blue/orange/red (label_replace on status code).
9. Time series "Latency p50/p95/p99".
10. Bar chart (horizontal) "Requests per route" last 15m.
11. Bar gauge (LCD) "Top consumers" req/s.
12. Pie chart (donut) "Status mix" last 15m.
13. State timeline "Health" — success rate over time with the same thresholds.
14. Status history "Error rate per route" — (4xx+5xx)/all per route.
15. Heatmap "Latency distribution" from kong_latency_total_seconds_bucket (format heatmap, Spectral).
16. Histogram "p95 per route".
17. Time series stacked "Where time goes": upstream vs internal (Kong) p95.
18. Table "Route health": per route req/s (gauge cell), error rate (color background), p95 (color text) — merge 3 instant queries.
19. Time series "Bandwidth" egress/ingress, and a Pie "Methods".
Then make it a public dashboard (Share externally) and give me the link.
