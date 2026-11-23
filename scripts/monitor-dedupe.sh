#!/usr/bin/env bash
# Splits anomalies into already-tracked vs new, using the fingerprint markers in open
# `monitoring` issues:
#   incident issues:          <!-- monitor-fp:<fp> -->
#   the suppressed-signals issue (label monitoring-suppressed):
#                             <!-- monitor-fp:<fp> suppressed=YYYY-MM-DD -->
# Suppressions EXPIRE after $SUPPRESS_DAYS (default 14) days; an undated marker in the
# suppressed issue counts as expired. An expired anomaly is "new" again, so a regression on
# a once-noisy signal is investigated instead of staying silent forever.
# Tracked (non-suppressed) issues get a short occurrence comment, at most once per ~20h
# per issue. Only NEW anomalies go to the Claude investigation.
#
# Usage: REPO=... GH_TOKEN=... OUT=.claude-out monitor-dedupe.sh
# Reads $OUT/anomalies.json, writes $OUT/anomalies.tagged.json and $OUT/new-anomalies.json.
# ISSUES_JSON=<file> replaces the `gh issue list` call (for local testing).

source "$(dirname "$0")/lib.sh"
: "${OUT:=.claude-out}" "${SUPPRESS_DAYS:=14}"

if [ -n "${ISSUES_JSON:-}" ]; then
  issues="$(cat "$ISSUES_JSON")"
else
  issues="$(gh issue list --repo "$REPO" --label monitoring --state open --limit 200 \
    --json number,body,updatedAt,labels)"
fi
since="$(date -u -d "${SUPPRESS_DAYS} days ago" +%F 2>/dev/null || date -u -v-"${SUPPRESS_DAYS}"d +%F)"

jq -c --argjson issues "$issues" --arg since "$since" '
  # Every marker in every open monitoring issue: {fp, date, issue, suppressed}.
  [ $issues[] | . as $i
    | ([$i.labels[]?.name] | index("monitoring-suppressed") != null) as $sup
    | ($i.body // "")
    | [scan("<!-- monitor-fp:([0-9a-f]+)(?: suppressed=([0-9]{4}-[0-9]{2}-[0-9]{2}))? -->")][]
    | {fp: .[0], date: .[1], issue: $i.number, suppressed: $sup} ] as $markers
  | .anomalies |= map(. as $a
      | [ $markers[] | select(.fp == $a.fingerprint) ] as $m
      | ([ $m[] | select(.suppressed | not) ] | first) as $incident
      | ([ $m[] | select(.suppressed and .date != null and .date >= $since) ] | first) as $sup
      | ($incident // $sup) as $hit
      | . + { issue: ($hit.issue // null),
              suppressed: ($hit != null and $hit.suppressed),
              suppressionExpired: ($hit == null and ([ $m[] | select(.suppressed) ] | length) > 0) })
' "$OUT/anomalies.json" > "$OUT/anomalies.tagged.json"

jq '.anomalies |= map(select(.issue == null))' "$OUT/anomalies.tagged.json" > "$OUT/new-anomalies.json"

expired="$(jq '[.anomalies[] | select(.suppressionExpired)] | length' "$OUT/anomalies.tagged.json")"
suppressed="$(jq '[.anomalies[] | select(.suppressed)] | length' "$OUT/anomalies.tagged.json")"
tracked="$(jq '[.anomalies[] | select(.issue != null and (.suppressed | not))] | length' "$OUT/anomalies.tagged.json")"
log "${tracked} tracked, ${suppressed} suppressed, ${expired} with an expired suppression (re-investigated)"

# Occurrence updates on tracked (non-suppressed) issues.
cutoff="$(date -u -d '20 hours ago' +%FT%TZ 2>/dev/null || date -u -v-20H +%FT%TZ)"
lookback="$(jq -r .lookback "$OUT/anomalies.json")"
for n in $(jq -r '[.anomalies[] | select(.issue != null and (.suppressed | not)) | .issue] | unique | .[]' "$OUT/anomalies.tagged.json"); do
  updated="$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .updatedAt' <<<"$issues")"
  if [[ "$updated" > "$cutoff" ]]; then log "#$n updated recently; skipping occurrence comment"; continue; fi
  table="$(jq -r --argjson n "$n" '
    .anomalies[] | select(.issue == $n)
    | "- `\(.query)` · \(.key | tostring | .[0:120]) · " +
      (.data | (.failed // .occurrences // .failures // .p95 // .httpCode // "?") | tostring)' "$OUT/anomalies.tagged.json" | defang)"
  gh_write issue comment "$n" --repo "$REPO" --body "Still occurring in the last ${lookback} ($(date -u '+%F %H:%MZ')):

${table}

<sub>Monitor run: ${RUN_URL:-local}</sub>"
done

new="$(jq '.anomalies | length' "$OUT/new-anomalies.json")"
log "$new new anomaly(ies) need investigation"
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "new=$new" >> "$GITHUB_OUTPUT"; fi
exit 0
