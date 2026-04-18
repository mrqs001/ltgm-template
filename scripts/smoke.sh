#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

epoch_seconds_now() {
  python3 - <<'PY'
import time
print(int(time.time()))
PY
}

epoch_seconds_ago() {
  local seconds="$1"
  python3 - "$seconds" <<'PY'
import sys
import time
print(int(time.time()) - int(sys.argv[1]))
PY
}

epoch_nanos_now() {
  python3 - <<'PY'
import time
print(time.time_ns())
PY
}

epoch_nanos_ago() {
  local seconds="$1"
  python3 - "$seconds" <<'PY'
import sys
import time
print(time.time_ns() - (int(sys.argv[1]) * 1_000_000_000))
PY
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local attempts="${3:-60}"

  for _ in $(seq 1 "$attempts"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "ready: $name"
      return 0
    fi
    sleep 2
  done

  echo "timed out waiting for $name at $url" >&2
  return 1
}

wait_for_prom_result() {
  local name="$1"
  local query="$2"
  local attempts="${3:-30}"

  for _ in $(seq 1 "$attempts"); do
    local response
    response="$(curl -fsS --get 'http://localhost:9009/prometheus/api/v1/query' --data-urlencode "query=$query")"
    if PROM_JSON="$response" python - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["PROM_JSON"])
sys.exit(0 if data.get("data", {}).get("result", []) else 1)
PY
    then
      echo "ready: $name"
      return 0
    fi
    sleep 2
  done

  echo "timed out waiting for Prometheus result: $name" >&2
  return 1
}

wait_for_exemplars() {
  local name="$1"
  local query="$2"
  local attempts="${3:-30}"

  for _ in $(seq 1 "$attempts"); do
    local response
    response="$(curl -fsS --get 'http://localhost:9009/prometheus/api/v1/query_exemplars' \
      --data-urlencode "query=$query" \
      --data-urlencode "start=$(epoch_seconds_ago 900)" \
      --data-urlencode "end=$(epoch_seconds_now)")"
    if [ "$(PROM_JSON="$response" python - <<'PY'
import json
import os

data = json.loads(os.environ["PROM_JSON"])
print("yes" if data.get("data", []) else "no")
PY
)" = "yes" ]; then
      echo "ready: $name"
      return 0
    fi
    sleep 2
  done

  echo "timed out waiting for exemplars: $name" >&2
  return 1
}

wait_for_trace_services() {
  local trace_id="$1"
  local attempts="${2:-30}"

  for _ in $(seq 1 "$attempts"); do
    local response
    response="$(curl -sS "http://localhost:3200/api/traces/$trace_id" || true)"
    if TRACE_JSON="$response" python - <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ["TRACE_JSON"])
except json.JSONDecodeError:
    sys.exit(1)

services = set()
for batch in data.get("batches", []):
    resource = batch.get("resource", {})
    attrs = resource.get("attributes", [])
    for attr in attrs:
        if attr.get("key") == "service.name":
            value = attr.get("value", {})
            for field in ("stringValue", "value"):
                if field in value:
                    services.add(value[field])

sys.exit(0 if {"checkout-api", "inventory-api"}.issubset(services) else 1)
PY
    then
      return 0
    fi
    sleep 2
  done

  echo "timed out waiting for Tempo trace data for trace_id=$trace_id" >&2
  return 1
}

wait_for_loki_logs() {
  local trace_id="$1"
  local attempts="${2:-30}"

  for _ in $(seq 1 "$attempts"); do
    local response
    response="$(curl -fsS --get 'http://localhost:3100/loki/api/v1/query_range' \
      --data-urlencode 'query={service_name="checkout-api"} | json | trace_id="'"$trace_id"'"' \
      --data-urlencode "start=$(epoch_nanos_ago 300)" \
      --data-urlencode "end=$(epoch_nanos_now)")"
    if LOKI_JSON="$response" python - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["LOKI_JSON"])
streams = data.get("data", {}).get("result", [])
sys.exit(0 if streams else 1)
PY
    then
      return 0
    fi
    sleep 2
  done

  echo "timed out waiting for Loki logs for trace_id=$trace_id" >&2
  return 1
}

query_prom() {
  local query="$1"
  curl -fsS --get 'http://localhost:9009/prometheus/api/v1/query' --data-urlencode "query=$query"
}

wait_for_url "grafana" "http://localhost:3000/api/health"
wait_for_url "loki" "http://localhost:3100/ready"
wait_for_url "tempo" "http://localhost:3200/ready"
wait_for_url "mimir" "http://localhost:9009/ready"
wait_for_url "checkout-api" "http://localhost:8000/healthz"

REQUEST_BODY='{"user_id":"demo-user","sku":"sku-1","quantity":1,"mode":"ok"}'
CHECKOUT_RESPONSE="$(curl -fsS -X POST http://localhost:8000/api/checkout -H 'Content-Type: application/json' -d "$REQUEST_BODY")"
TRACE_ID="$(RESPONSE="$CHECKOUT_RESPONSE" python - <<'PY'
import json
import os
payload = json.loads(os.environ["RESPONSE"])
print(payload["trace_id"])
PY
)"

echo "trace_id=$TRACE_ID"

wait_for_trace_services "$TRACE_ID" 30

wait_for_loki_logs "$TRACE_ID" 30

wait_for_prom_result "checkout metrics" 'sum(demo_checkout_requests_total)' 30
METRICS_RESPONSE="$(query_prom 'sum(demo_checkout_requests_total)')"
METRICS_OK="$(PROM_JSON="$METRICS_RESPONSE" python - <<'PY'
import json
import os
data = json.loads(os.environ["PROM_JSON"])
result = data.get("data", {}).get("result", [])
print("yes" if result else "no")
PY
)"
[ "$METRICS_OK" = "yes" ]

wait_for_prom_result "service-graph" 'sum(traces_service_graph_request_total{client="checkout-api",server="inventory-api"})' 30
SERVICE_GRAPH_RESPONSE="$(query_prom 'sum(traces_service_graph_request_total{client="checkout-api",server="inventory-api"})')"
SERVICE_GRAPH_OK="$(PROM_JSON="$SERVICE_GRAPH_RESPONSE" python - <<'PY'
import json
import os
data = json.loads(os.environ["PROM_JSON"])
result = data.get("data", {}).get("result", [])
print("yes" if result else "no")
PY
)"
[ "$SERVICE_GRAPH_OK" = "yes" ]

wait_for_exemplars "checkout exemplars" 'demo_checkout_duration_seconds_bucket{service="checkout-api"}' 30
START_TS="$(epoch_seconds_ago 900)"
END_TS="$(epoch_seconds_now)"
EXEMPLAR_RESPONSE="$(curl -fsS --get 'http://localhost:9009/prometheus/api/v1/query_exemplars' \
  --data-urlencode 'query=demo_checkout_duration_seconds_bucket{service="checkout-api"}' \
  --data-urlencode "start=$START_TS" \
  --data-urlencode "end=$END_TS")"
EXEMPLAR_OK="$(PROM_JSON="$EXEMPLAR_RESPONSE" python - <<'PY'
import json
import os
data = json.loads(os.environ["PROM_JSON"])
result = data.get("data", [])
print("yes" if result else "no")
PY
)"
[ "$EXEMPLAR_OK" = "yes" ]

echo "smoke test passed"
