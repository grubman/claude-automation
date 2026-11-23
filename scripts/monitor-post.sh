#!/usr/bin/env bash
# Turns the investigator's $OUT/incidents.json into GitHub issues (labels: monitoring, bug).
# Fingerprints Claude judged to be noise go into ONE "Monitoring: suppressed signals" issue
# with a dated marker; monitor-dedupe.sh ignores them for $SUPPRESS_DAYS (default 14) days,
# after which they are investigated again. Expired and re-added entries are pruned whenever
# the issue is rewritten. Close the issue to un-suppress everything.
# If the investigation produced nothing usable, files the raw anomalies so nothing is lost.
#
# Usage: REPO=... GH_TOKEN=... OUT=.claude-out RUN_URL=... monitor-post.sh

source "$(dirname "$0")/lib.sh"
: "${OUT:=.claude-out}" "${SUPPRESS_DAYS:=14}"
INC="$OUT/incidents.json"

markers() { jq -r '.[] | "<!-- monitor-fp:" + . + " -->"'; }

if [ ! -s "$INC" ] || ! jq -e '.incidents | type == "array"' "$INC" >/dev/null 2>&1; then
  log "no valid incidents.json; filing raw anomalies"
  raw="$(jq -r '.anomalies[] | "- `\(.query)` · \(.key | tostring | .[0:150])\n  ```json\n  \(.data | tostring | .[0:600])\n  ```"' "$OUT/new-anomalies.json" | defang)"
  gh_write issue create --repo "$REPO" --label monitoring --label bug \
    --title "Monitoring: $(jq '.anomalies | length' "$OUT/new-anomalies.json") uninvestigated anomaly(ies)" \
    --body "The automated investigation failed (${RUN_URL:-}), so here is the raw sweep output.

${raw}

$(jq -c '[.anomalies[].fingerprint]' "$OUT/new-anomalies.json" | markers)"
  exit 0
fi

count="$(jq '.incidents | length' "$INC")"
for i in $(seq 0 $((count - 1))); do
  inc="$(jq -c ".incidents[$i]" "$INC")"
  title="$(jq -r '.title' <<<"$inc" | defang)"
  sev="$(jq -r '.severity // "medium"' <<<"$inc")"
  body="$(jq -r '.body' <<<"$inc" | defang)

---
**Severity:** ${sev} · **Detected by:** [monitor run](${RUN_URL:-}) · Add the \`claude\` label to have Claude draft a fix.
$(jq -c '.fingerprints' <<<"$inc" | markers)"
  gh_write issue create --repo "$REPO" --title "[monitor] ${title}" --body "$body" --label monitoring --label bug
done

noise="$(jq -c '[.noise[]? | {fingerprint, reason}]' "$INC")"
if [ "$(jq length <<<"$noise")" -gt 0 ]; then
  today="$(date -u +%F)"
  until_d="$(date -u -d "${SUPPRESS_DAYS} days" +%F 2>/dev/null || date -u -v+"${SUPPRESS_DAYS}"d +%F)"
  since="$(date -u -d "${SUPPRESS_DAYS} days ago" +%F 2>/dev/null || date -u -v-"${SUPPRESS_DAYS}"d +%F)"
  header="Signals the investigator judged to be noise. The monitor ignores each fingerprint listed here for ${SUPPRESS_DAYS} days from the date in its marker, then investigates it again if it still fires. Edit this issue to remove a line, or close it to un-suppress everything."
  lines="$(jq -r --arg today "$today" --arg until "$until_d" \
    '.[] | "- `\(.fingerprint)` — \(.reason) (suppressed until \($until))\n  <!-- monitor-fp:\(.fingerprint) suppressed=\($today) -->"' <<<"$noise" | defang)"
  sup="$(gh issue list --repo "$REPO" --label monitoring-suppressed --state open --json number -q '.[0].number // empty')"
  if [ -z "$sup" ]; then
    gh_write issue create --repo "$REPO" --label monitoring --label monitoring-suppressed \
      --title "Monitoring: suppressed signals" --body "${header}

${lines}"
  else
    cur="$(gh issue view "$sup" --repo "$REPO" --json body -q .body)"
    # Drop entries (bullet + marker line) that are re-added now, expired, or undated.
    readd=" $(jq -r '[.[].fingerprint] | join(" ")' <<<"$noise") "
    kept="$(printf '%s\n' "$cur" | awk -v since="$since" -v readd="$readd" '
      function flush() { if (pending != "") print pending; pending = "" }
      /^- `[0-9a-f]+`/ { flush(); pending = $0; next }
      match($0, /<!-- monitor-fp:[0-9a-f]+/) {
        fp = substr($0, RSTART + 16, RLENGTH - 16)
        d = ""
        if (match($0, /suppressed=[0-9-]+/)) d = substr($0, RSTART + 11, RLENGTH - 11)
        if (index(readd, " " fp " ") || d == "" || d < since) { pending = ""; next }
        flush(); print; next
      }
      { flush(); print }
      END { flush() }')"
    # Refresh the header so older issues pick up the expiry wording.
    kept="$(printf '%s\n' "$kept" | sed '1{/^Signals the investigator judged to be noise/d;}')"
    gh_write issue edit "$sup" --repo "$REPO" --body "${header}
${kept}
${lines}"
  fi
fi
log "filed $count incident(s), suppressed $(jq length <<<"$noise") signal(s)"
