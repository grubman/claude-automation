#!/usr/bin/env bash
# Stage A of the live-site monitor: cheap and deterministic, no LLM.
# Runs synthetic checks plus every KQL query in $QUERIES_DIR against App Insights and
# writes each anomaly (with a stable fingerprint) to $OUT/anomalies.json.
#
# Usage: REPO=owner/name APP_ID=<App Insights application id> LOOKBACK=6h \
#        API_BASE_URL=https://... HEALTH_PATH=/health FRONTEND_URL=https://... \
#        QUERIES_DIR=.claude-out/monitor-queries OUT=.claude-out monitor-sweep.sh
# Requires an authenticated `az` with the application-insights extension.
# Queries use {{LOOKBACK}} as a placeholder and must return a `key` column.

REPO="${REPO:-local}"
source "$(dirname "$0")/lib.sh"

: "${APP_ID:?}" "${LOOKBACK:=6h}" "${OUT:=.claude-out}" "${QUERIES_DIR:=$OUT/monitor-queries}"
mkdir -p "$OUT"
[[ "$LOOKBACK" =~ ^[0-9]+[mhd]$ ]] || { log "LOOKBACK must look like 30m / 6h / 1d"; exit 1; }

anoms="[]"
add() {  # add <query> <key> <json-data>
  local fp; fp="$(sha12 "$1|$2")"
  anoms="$(jq -c --arg q "$1" --arg k "$2" --arg fp "$fp" --argjson d "$3" \
    '. + [{query: $q, key: $k, fingerprint: $fp, data: $d}]' <<<"$anoms")"
}

# ── Synthetic checks ────────────────────────────────────────────────────────
check() {  # check <name> <url>
  local code t
  # -w prints even when the connection fails (code 000), so don't append a fallback.
  read -r code t <<<"$(curl -s -o /dev/null -m 20 -w '%{http_code} %{time_total}' "$2" || true)"
  code="${code:-000}"; t="${t:-20}"
  log "synthetic $1: HTTP $code in ${t}s"
  if [ "$code" -lt 200 ] || [ "$code" -ge 400 ]; then
    add synthetic "$1" "$(jq -nc --arg u "$2" --arg c "$code" --arg t "$t" '{url: $u, httpCode: $c, seconds: $t}')"
  elif awk "BEGIN{exit !($t > 5)}"; then
    add synthetic-slow "$1" "$(jq -nc --arg u "$2" --arg t "$t" '{url: $u, seconds: $t}')"
  fi
}
hp="${HEALTH_PATH:-/health}"; [[ "$hp" == /* ]] || hp="/$hp"
if [ -n "${API_BASE_URL:-}" ]; then check api-health "${API_BASE_URL%/}${hp}"; fi
if [ -n "${FRONTEND_URL:-}" ]; then check frontend "${FRONTEND_URL%/}/"; fi

# ── App Insights queries ────────────────────────────────────────────────────
shopt -s nullglob
failed_queries=0; total_queries=0
for f in "$QUERIES_DIR"/*.kql; do
  name="$(basename "$f" .kql)"; total_queries=$((total_queries + 1))
  q="$(sed "s/{{LOOKBACK}}/${LOOKBACK}/g" "$f")"
  if ! res="$(az monitor app-insights query --app "$APP_ID" --analytics-query "$q" --offset 8d -o json 2>"$OUT/$name.err")"; then
    log "query $name failed: $(head -c 300 "$OUT/$name.err")"; failed_queries=$((failed_queries + 1)); continue
  fi
  rows="$(jq -c '.tables[0] as $t | [ $t.rows[] | [ [$t.columns[].name], . ] | transpose | map({(.[0]): .[1]}) | add ]' <<<"$res")"
  log "query $name: $(jq length <<<"$rows") anomalous row(s)"
  while read -r row; do
    [ -n "$row" ] && add "$name" "$(jq -r '.key | tostring' <<<"$row")" "$row"
  done < <(jq -c '.[]' <<<"$rows")
done
[ "$total_queries" -gt 0 ] || log "no .kql files in $QUERIES_DIR"
if [ "$total_queries" -gt 0 ] && [ "$failed_queries" -ge "$total_queries" ]; then
  log "every App Insights query failed — check credentials / APP_ID"; exit 1
fi

jq --arg lb "$LOOKBACK" --arg at "$(date -u +%FT%TZ)" '{lookback: $lb, generatedAt: $at, anomalies: .}' \
  <<<"$anoms" > "$OUT/anomalies.json"
count="$(jq length <<<"$anoms")"
log "$count anomaly(ies) → $OUT/anomalies.json"
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "count=$count" >> "$GITHUB_OUTPUT"; fi
exit 0
