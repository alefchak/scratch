#!/usr/bin/env bash
# One-off: delete retention_policy="Inf" logs older than KEEP_DAYS in the CURRENT kube context.
# Submits a Loki delete request. It can be cancelled until delete_request_cancel_period
# (24h by default) has passed.
set -euo pipefail

KEEP_DAYS="${KEEP_DAYS:-30}"
SVC="${SVC:-svc/loki-backend}"          # svc/loki-compactor in distributed mode
NS="${NS:-monitoring}"
TENANT="${TENANT:-}"                     # leave empty if auth_enabled: false
QUERY='{retention_policy="Inf"}'
START="${START:-2020-01-01T00:00:00Z}"   # earlier than your oldest logs
PORT="${PORT:-3100}"

CTX=$(kubectl config current-context)
# GNU date, falling back to BSD/macOS date
END=$(date -u -d "-${KEEP_DAYS} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -v-"${KEEP_DAYS}"d +%Y-%m-%dT%H:%M:%SZ)

echo "Context : $CTX"
echo "Query   : $QUERY"
echo "Window  : $START -> $END (keeps the last $KEEP_DAYS days)"
read -rp "Type the context name to confirm deletion in THIS cluster: " CONFIRM
[[ "$CONFIRM" == "$CTX" ]] || { echo "Mismatch, aborting."; exit 1; }

kubectl -n "$NS" port-forward "$SVC" "$PORT:3100" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF"' EXIT
sleep 3

HDR=()
[[ -n "$TENANT" ]] && HDR=(-H "X-Scope-OrgID: $TENANT")

curl -fsS -X POST -G ${HDR[@]+"${HDR[@]}"} \
  --data-urlencode "query=$QUERY" \
  --data-urlencode "start=$START" \
  --data-urlencode "end=$END" \
  "http://localhost:$PORT/loki/api/v1/delete"

echo "Submitted. Pending requests (cancel within the cancel period if wrong):"
curl -fsS ${HDR[@]+"${HDR[@]}"} "http://localhost:$PORT/loki/api/v1/delete" | jq '.[] | select(.status=="received")'
