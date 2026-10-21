#!/usr/bin/env python3
"""Generates dashboards/kong-command-center.json (Kong Cloud via OTel → Grafana Cloud Prometheus)."""
import json, os
DS = {"type": "prometheus", "uid": "${DS_PROMETHEUS}"}
ST = "http_response_status_code"
def R(sel=""):  # request counter selector
    return "http_server_request_count_total{job=\"kong\"" + ("," + sel if sel else "") + "}"
OK, E5, E45, BLK = ST + '=~"[23].."', ST + '=~"5.."', ST + '=~"[45].."', ST + '=~"401|403|429"'
HASC = 'kong_auth_consumer_name!=""'
LAT = 'kong_latency_total_seconds_bucket{job="kong"}'
def cls(inner): return 'sum by (class) (label_replace(' + inner + ', "class", "${1}xx", "' + ST + '", "(.).."))'
def q(p, w): return "histogram_quantile(" + p + ", sum by (le) (rate(" + LAT + "[" + w + "])))"

n = [0]
def t(expr, legend=None, instant=False, fmt=None):
    d = {"datasource": DS, "expr": expr, "editorMode": "code"}
    if legend: d["legendFormat"] = legend
    if instant: d.update(instant=True, range=False)
    if fmt: d["format"] = fmt
    return d
def P(title, typ, targets, grid, unit=None, fd=None, opt=None, ov=None, tr=None, desc=None):
    n[0] += 1
    for i, x in enumerate(targets): x["refId"] = chr(65 + i)
    d = {"unit": unit} if unit else {}
    d.update(fd or {})
    p = {"id": n[0], "type": typ, "title": title, "datasource": DS, "gridPos": dict(zip("xywh", grid)),
         "targets": targets, "fieldConfig": {"defaults": d, "overrides": ov or []}, "options": opt or {}}
    if tr: p["transformations"] = tr
    if desc: p["description"] = desc
    return p
def TH(*s): return {"color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in s]}}
def C(name, c): return {"matcher": {"id": "byName", "options": name}, "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": c}}]}
CLS = [C("2xx", "green"), C("3xx", "blue"), C("4xx", "orange"), C("5xx", "red")]
STAT = {"colorMode": "background_solid", "graphMode": "area", "justifyMode": "center", "reduceOptions": {"calcs": ["lastNotNull"]}}
GAUGE = {"showThresholdMarkers": True, "reduceOptions": {"calcs": ["lastNotNull"]}}
LINE = {"custom": {"lineWidth": 2, "fillOpacity": 18, "gradientMode": "opacity", "showPoints": "never", "lineInterpolation": "smooth"}}
BARS = {"custom": {"drawStyle": "bars", "lineWidth": 0, "fillOpacity": 85, "stacking": {"mode": "normal"}, "showPoints": "never"}}
LEG = {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "desc"}}
ROW = lambda title, y: {"id": 900 + y, "type": "row", "title": title, "collapsed": False, "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []}

panels = [
  # 0 · Text header
  {"id": 999, "type": "text", "title": "", "gridPos": {"x": 0, "y": 0, "w": 24, "h": 3},
   "options": {"mode": "markdown", "content":
     "## 🦍 Kong Cloud — Command Center\nLive traffic of the Konnect serverless gateway · OpenTelemetry → Grafana Cloud · "
     "7 APIs, 5 consumers, key-auth, rate limiting · source: [mbergo/kong-cvs](https://github.com/mbergo/kong-cvs)"}},
  # 1 · Stats + gauges
  P("Requests / min", "stat", [t("sum(rate(" + R() + "[5m])) * 60")], (0, 3, 4, 5), "short", TH(("#3274D9", None)), STAT),
  P("Success rate", "gauge", [t("sum(rate(" + R(OK) + "[5m])) / sum(rate(" + R() + "[5m]))")], (4, 3, 4, 5), "percentunit",
    dict(min=0, max=1, decimals=1, **TH(("red", None), ("orange", 0.85), ("green", 0.95))), GAUGE),
  P("Latency p95", "gauge", [t(q("0.95", "5m"))], (8, 3, 4, 5), "s",
    dict(min=0, max=3, decimals=2, **TH(("green", None), ("orange", 0.8), ("red", 1.5))), GAUGE),
  P("5xx errors", "gauge", [t("sum(rate(" + R(E5) + "[5m])) / sum(rate(" + R() + "[5m]))")], (12, 3, 4, 5), "percentunit",
    dict(min=0, max=0.25, decimals=1, **TH(("green", None), ("orange", 0.03), ("red", 0.1))), GAUGE),
  P("Blocked / min", "stat", [t("sum(rate(" + R(BLK) + "[5m])) * 60")], (16, 3, 4, 5), "short", TH(("#FF780A", None)), STAT,
    desc="401 (no key) + 403 + 429 (rate limited)"),
  P("Active consumers", "stat", [t("count(sum by (kong_auth_consumer_name) (rate(" + R(HASC) + "[5m])) > 0)")], (20, 3, 4, 5), "short",
    TH(("#8F3BB8", None)), STAT),
  ROW("Traffic", 8),
  P("Traffic by status class", "timeseries", [t(cls("rate(" + R() + "[$__rate_interval])"), "{{class}}")], (0, 9, 12, 8), "reqps", BARS, LEG, CLS),
  P("Latency p50 · p95 · p99", "timeseries", [t(q(p, "$__rate_interval"), "p" + p[2:4]) for p in ("0.50", "0.95", "0.99")], (12, 9, 12, 8), "s",
    LINE, LEG, [C("p50", "green"), C("p95", "yellow"), C("p99", "red")]),
  ROW("Who & what", 17),
  P("Requests per route (15m)", "bargauge", [t("sum by (kong_route_name) (increase(" + R() + "[15m]))", "{{kong_route_name}}")],
    (0, 18, 8, 8), "short", {"color": {"mode": "palette-classic"}},
    {"displayMode": "basic", "orientation": "horizontal", "showUnfilled": False, "valueMode": "color", "reduceOptions": {"calcs": ["lastNotNull"]}}),
  P("Top consumers (bar gauge)", "bargauge", [t("sum by (kong_auth_consumer_name) (rate(" + R() + "[5m]))", "{{kong_auth_consumer_name}}")],
    (8, 18, 8, 8), "reqps", {"color": {"mode": "continuous-GrYlRd"}},
    {"displayMode": "lcd", "orientation": "horizontal", "showUnfilled": True, "reduceOptions": {"calcs": ["lastNotNull"]}}),
  P("Status mix · 15m (donut)", "piechart", [t(cls("increase(" + R() + "[15m])"), "{{class}}")], (16, 18, 8, 8), "short", None,
    {"pieType": "donut", "displayLabels": ["percent"], "legend": {"displayMode": "table", "placement": "right", "values": ["value", "percent"]},
     "reduceOptions": {"calcs": ["lastNotNull"]}}, CLS),
  ROW("Health over time", 26),
  P("Health timeline (success rate)", "state-timeline",
    [t("sum(rate(" + R(OK) + "[5m])) / sum(rate(" + R() + "[5m]))", "gateway")], (0, 27, 12, 4), "percentunit",
    TH(("red", None), ("orange", 0.85), ("green", 0.95)), {"showValue": "never", "mergeValues": True, "rowHeight": 0.8, "legend": {"showLegend": False}}),
  P("Error rate per route (status history)", "status-history",
    [t("sum by (kong_route_name) (rate(" + R(E45) + "[5m])) / sum by (kong_route_name) (rate(" + R() + "[5m]))", "{{kong_route_name}}")],
    (12, 27, 12, 8), "percentunit", TH(("green", None), ("orange", 0.15), ("red", 0.5)),
    {"showValue": "never", "rowHeight": 0.85, "colWidth": 0.9, "legend": {"showLegend": False}}),
  P("Requests per second trend (sparkline stats per route)", "stat",
    [t("sum by (kong_route_name) (rate(" + R() + "[5m]))", "{{kong_route_name}}")], (0, 31, 12, 4), "reqps",
    {"color": {"mode": "palette-classic"}}, {"colorMode": "value", "graphMode": "area", "textMode": "value_and_name", "orientation": "horizontal",
     "reduceOptions": {"calcs": ["lastNotNull"]}}),
  ROW("Latency deep dive", 35),
  P("Latency distribution (heatmap)", "heatmap", [t("sum by (le) (increase(" + LAT + "[$__rate_interval]))", "{{le}}", fmt="heatmap")],
    (0, 36, 12, 8), None, None,
    {"calculate": False, "yAxis": {"unit": "s", "decimals": 2}, "color": {"mode": "scheme", "scheme": "Spectral", "reverse": True},
     "cellGap": 1, "tooltip": {"show": True, "yHistogram": True}, "legend": {"show": False}}),
  P("p95 per route (histogram)", "histogram",
    [t('histogram_quantile(0.95, sum by (le, kong_route_name) (rate(kong_latency_total_seconds_bucket{job="kong"}[$__rate_interval])))', "{{kong_route_name}}")],
    (12, 36, 6, 8), "s", {"custom": {"fillOpacity": 70}}, {"bucketCount": 15, "combine": True, "legend": {"showLegend": False}}),
  P("Where the time goes (p95)", "timeseries", [
      t('histogram_quantile(0.95, sum by (le) (rate(kong_latency_upstream_seconds_bucket{job="kong"}[$__rate_interval])))', "Upstream"),
      t('histogram_quantile(0.95, sum by (le) (rate(kong_latency_internal_seconds_bucket{job="kong"}[$__rate_interval])))', "Kong")],
    (18, 36, 6, 8), "s", {"custom": {"fillOpacity": 70, "stacking": {"mode": "normal"}, "showPoints": "never", "lineInterpolation": "smooth"}},
    LEG, [C("Upstream", "purple"), C("Kong", "green")]),
  ROW("Routes & bandwidth", 44),
  P("Route health (table)", "table", [
      t("sum by (kong_route_name) (rate(" + R() + "[5m]))", "{{kong_route_name}}"),
      t("sum by (kong_route_name) (rate(" + R(E45) + "[5m])) / sum by (kong_route_name) (rate(" + R() + "[5m]))", "{{kong_route_name}}"),
      t('histogram_quantile(0.95, sum by (le, kong_route_name) (rate(kong_latency_total_seconds_bucket{job="kong"}[5m])))', "{{kong_route_name}}")],
    (0, 45, 14, 9), None, None, {"showHeader": True, "cellHeight": "sm"},
    [{"matcher": {"id": "byName", "options": "Req/s"}, "properties": [{"id": "unit", "value": "reqps"}, {"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "lcd"}}]},
     {"matcher": {"id": "byName", "options": "Error rate"}, "properties": [{"id": "unit", "value": "percentunit"},
       {"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "gradient"}},
       {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "orange", "value": 0.15}, {"color": "red", "value": 0.5}]}}]},
     {"matcher": {"id": "byName", "options": "p95"}, "properties": [{"id": "unit", "value": "s"}, {"id": "custom.cellOptions", "value": {"type": "color-text"}}]}],
    tr=[{"id": "joinByLabels", "options": {"value": "__name__", "join": ["kong_route_name"]}},
        {"id": "reduce", "options": {"reducers": ["lastNotNull"], "mode": "reduceFields", "includeTimeField": False}},
        {"id": "organize", "options": {"renameByName": {"kong_route_name": "Route", "A": "Req/s", "B": "Error rate", "C": "p95"}}}]),
  P("Bandwidth", "timeseries", [
      t('sum(rate(http_server_response_size_bytes_sum{job="kong"}[$__rate_interval]))', "Egress"),
      t('sum(rate(http_server_request_size_bytes_sum{job="kong"}[$__rate_interval]))', "Ingress")],
    (14, 45, 10, 5), "Bps", LINE, LEG),
  P("Methods", "piechart", [t("sum by (http_request_method) (increase(" + R() + "[15m]))", "{{http_request_method}}")],
    (14, 50, 5, 4), "short", None, {"pieType": "pie", "legend": {"displayMode": "list", "placement": "right"}, "reduceOptions": {"calcs": ["lastNotNull"]}}),
  P("Rate-limited (429) / min", "stat", [t("sum(rate(" + R(ST + '="429"') + "[5m])) * 60")], (19, 50, 5, 4), "short",
    TH(("green", None), ("orange", 1), ("red", 10)), STAT),
]
dash = {"__inputs": [{"name": "DS_PROMETHEUS", "label": "Prometheus", "type": "datasource", "pluginId": "prometheus", "pluginName": "Prometheus"}],
        "__requires": [{"type": "datasource", "id": "prometheus", "name": "Prometheus", "version": "1.0.0"}],
        "title": "Kong Cloud — Command Center", "uid": "kong-command-center", "tags": ["kong", "konnect", "otel"],
        "schemaVersion": 39, "version": 1, "time": {"from": "now-1h", "to": "now"}, "refresh": "30s", "graphTooltip": 1,
        "templating": {"list": []}, "annotations": {"list": []}, "panels": panels}
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kong-command-center.json")
json.dump(dash, open(out, "w"), indent=2)
print(f"{out}: {len(panels)} panels, types: {sorted({p['type'] for p in panels})}")
