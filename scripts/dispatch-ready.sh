#!/usr/bin/env bash
# Labels the next ready sub-issues of an epic with `claude`, so claude.yml builds them.
#
# A sub-issue is "ready" when it is open, not already handed off / blocked, and every
# issue it depends on is closed. Independent items are dispatched in parallel, capped
# at MAX_PARALLEL in-flight items. When every sub-issue is closed, the epic is closed.
#
# Usage: REPO=owner/name GH_TOKEN=<PAT> dispatch-ready.sh <epic-number>
# The token MUST be a PAT / App token: labels added with GITHUB_TOKEN don't trigger
# workflows, so claude.yml would never start.
#
# Sub-issues are recognised by the marker create-subissues.sh writes in their body:
#   <!-- claude-plan parent=<epic> order=<i> depends=<n,n,...> -->

source "$(dirname "$0")/lib.sh"

PARENT="${1:?epic number required}"
MAX_PARALLEL="${MAX_PARALLEL:-3}"

items="$(gh issue list --repo "$REPO" --label claude-subtask --state all --limit 500 \
  --json number,state,labels,body |
  jq --argjson p "$PARENT" '
    [ .[]
      | (.body // "" | capture("<!-- claude-plan parent=(?<parent>[0-9]+) order=(?<order>[0-9]+) depends=(?<deps>[0-9,]*) -->")?) as $m
      | select($m != null and ($m.parent | tonumber) == $p)
      | { number, state,
          labels: [.labels[].name],
          order: ($m.order | tonumber),
          deps: ($m.deps | split(",") | map(select(. != "") | tonumber)) } ]
    | sort_by(.order)')"

total="$(jq length <<<"$items")"
if [ "$total" -eq 0 ]; then
  log "epic #$PARENT has no planned sub-issues; nothing to do"
  exit 0
fi

open_count="$(jq '[.[] | select(.state == "OPEN")] | length' <<<"$items")"
if [ "$open_count" -eq 0 ]; then
  if [ "$(gh issue view "$PARENT" --repo "$REPO" --json state -q .state)" = "OPEN" ]; then
    log "all $total sub-issues of #$PARENT are closed; closing the epic"
    gh_write issue comment "$PARENT" --repo "$REPO" \
      --body "All $total planned sub-issues are closed. Closing this epic."
    gh_write issue close "$PARENT" --repo "$REPO" --reason completed
  fi
  exit 0
fi

# Sub-issue numbers that are closed (dependencies may also point outside the plan,
# e.g. a pre-existing issue, so check those individually).
closed_nums="$(jq '[.[] | select(.state == "CLOSED") | .number]' <<<"$items")"

in_flight="$(jq '[.[] | select(.state == "OPEN" and (.labels | index("claude")))] | length' <<<"$items")"
slots=$(( MAX_PARALLEL - in_flight ))
log "epic #$PARENT: $total items, $open_count open, $in_flight in flight, $slots free slot(s)"
[ "$slots" -gt 0 ] || exit 0

candidates="$(jq -r '
  .[] | select(.state == "OPEN")
      | select([.labels[] | select(. == "claude" or . == "claude-failed" or . == "claude-needs-input" or . == "claude-hold" or . == "claude-paused")] | length == 0)
      | "\(.number) \(.deps | map(tostring) | join(","))"' <<<"$items")"

dispatched=0
while read -r num deps; do
  [ -n "${num:-}" ] || continue
  [ "$dispatched" -lt "$slots" ] || break
  ready=1
  for d in ${deps//,/ }; do
    if ! jq -e --argjson d "$d" 'index($d)' <<<"$closed_nums" >/dev/null; then
      # Not a closed plan item — maybe an external dependency.
      state="$(gh issue view "$d" --repo "$REPO" --json state -q .state 2>/dev/null || echo OPEN)"
      [ "$state" = "CLOSED" ] || { ready=0; break; }
    fi
  done
  if [ "$ready" -eq 1 ]; then
    log "dispatching #$num (deps: ${deps:-none})"
    gh_write issue edit "$num" --repo "$REPO" --add-label claude
    dispatched=$(( dispatched + 1 ))
  fi
done <<<"$candidates"

log "dispatched $dispatched sub-issue(s)"
