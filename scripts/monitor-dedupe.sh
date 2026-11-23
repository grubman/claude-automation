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
# Fixed and deployed: an anomaly whose fingerprint is on a `monitoring` issue CLOSED in the last
# $RESOLVED_DAYS days (normally by a merged `Closes #n` PR) is a leftover, not new, when it was
# last seen before the fix went live: the first successful push deploy of each workflow in
# $DEPLOY_WORKFLOWS that started after the close. While such a deploy is still running (or
# none succeeded yet) the fix isn't live, so it is skipped too. Seen after the fix went live →
# new again, tagged `regressionOf: <closed issue>`. Anomalies without `data.lastSeen` (e.g. the
# synthetic checks) can't be leftovers. Without DEPLOY_WORKFLOWS the close time is used.
#
# Usage: REPO=... GH_TOKEN=... OUT=.claude-out [DEPLOY_WORKFLOWS="a.yml b.yml"] monitor-dedupe.sh
# Reads $OUT/anomalies.json, writes $OUT/anomalies.tagged.json and $OUT/new-anomalies.json.
# ISSUES_JSON / CLOSED_ISSUES_JSON / DEPLOYS_JSON=<file> replace the gh calls (local testing).

source "$(dirname "$0")/lib.sh"
: "${OUT:=.claude-out}" "${SUPPRESS_DAYS:=14}" "${RESOLVED_DAYS:=7}" "${DEPLOY_WORKFLOWS:=}"

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

# ── Fixed and deployed: leftovers of recently closed incidents ─────────────────────────
if [ -n "${CLOSED_ISSUES_JSON:-}" ]; then
  closed="$(cat "$CLOSED_ISSUES_JSON")"
else
  closed_since="$(date -u -d "${RESOLVED_DAYS} days ago" +%F 2>/dev/null || date -u -v-"${RESOLVED_DAYS}"d +%F)"
  closed="$(gh issue list --repo "$REPO" --label monitoring --state closed --limit 100 \
    --search "closed:>=${closed_since}" --json number,body,closedAt,labels)"
fi
# Closing the suppressed-signals issue means "un-suppress", not "fixed".
closed="$(jq -c '[.[] | select([.labels[]?.name] | index("monitoring-suppressed") | not)]' <<<"$closed")"

deploys='[]'
if [ -n "${DEPLOYS_JSON:-}" ]; then
  deploys="$(cat "$DEPLOYS_JSON")"
elif [ -n "$DEPLOY_WORKFLOWS" ] && [ "$(jq length <<<"$closed")" -gt 0 ]; then
  branch="${DEFAULT_BRANCH:-$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name)}"
  for wf in $DEPLOY_WORKFLOWS; do
    r="$(gh run list --repo "$REPO" --workflow "$wf" --branch "$branch" --event push --limit 30 \
           --json createdAt,updatedAt,status,conclusion 2>/dev/null || echo '[]')"
    deploys="$(jq -c --arg wf "$wf" --argjson r "$r" '. + [$r[] | . + {wf: $wf}]' <<<"$deploys")"
  done
fi

# Per closed issue: its fingerprints and when its fix went live (epoch seconds, or "pending").
live="$(jq -c --argjson deploys "$deploys" '
  def ep: .[0:19] + "Z" | fromdateiso8601;
  map(. as $i | (($i.closedAt | ep) - 120) as $c        # deploy runs start right after the merge
    | [ $deploys | map(select((.createdAt | ep) >= $c)) | group_by(.wf)[]
        | sort_by(.createdAt)
        | (map(select(.status == "completed" and .conclusion == "success")) | first) as $ok
        | if $ok then ($ok.updatedAt | ep) else "pending" end ] as $per_wf
    | { issue: $i.number,
        fps: [ ($i.body // "") | scan("<!-- monitor-fp:([0-9a-f]+)") | .[0] ],
        liveAt: (if ($per_wf | length) == 0 then ($i.closedAt | ep)
                 elif ($per_wf | index("pending")) != null then "pending"
                 else ($per_wf | max) end) })' <<<"$closed")"

jq -c --argjson live "$live" '
  def ep: .[0:19] + "Z" | fromdateiso8601;
  .anomalies |= map(. as $a
    | if $a.issue != null then .
      else ([ $live[] | select(.fps | index($a.fingerprint)) ] | sort_by(.issue) | last) as $fix
        | if $fix == null then .
          else ($a.data.lastSeen // null | if . == null then null else ep end) as $seen
            | if $fix.liveAt == "pending" or ($seen != null and $seen <= $fix.liveAt)
              then . + { resolvedBy: $fix.issue }
              else . + { regressionOf: $fix.issue } end
          end
      end)
' "$OUT/anomalies.tagged.json" > "$OUT/anomalies.tagged.tmp" && mv "$OUT/anomalies.tagged.tmp" "$OUT/anomalies.tagged.json"
resolved="$(jq '[.anomalies[] | select(.resolvedBy)] | length' "$OUT/anomalies.tagged.json")"
[ "$resolved" = 0 ] || log "${resolved} anomaly(ies) are leftovers of fixed issues ($(jq -r '[.anomalies[] | select(.resolvedBy) | "#\(.resolvedBy)"] | unique | join(", ")' "$OUT/anomalies.tagged.json")): last seen before the fix went live, or the fix is not live yet; skipped"

jq '.anomalies |= map(select(.issue == null and (.resolvedBy | not)))' "$OUT/anomalies.tagged.json" > "$OUT/new-anomalies.json"

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
