#!/usr/bin/env bash
# Turns an approved plan into ordered GitHub sub-issues of an epic.
#
# Usage: REPO=owner/name GH_TOKEN=... create-subissues.sh <epic-number> <plan.json>
#
# plan.json (written by the planner, see plan.md):
#   { "summary": "...", "assumptions": ["..."],
#     "items": [ { "key": "a", "title": "...", "body": "...",
#                  "depends_on": ["<earlier key>"], "touches": ["path/..."] } ] }
#
# Items must be topologically ordered (a dependency always comes earlier).
# Re-running is safe: if sub-issues already exist for the epic, it refuses.

source "$(dirname "$0")/lib.sh"

PARENT="${1:?epic number required}"
PLAN="${2:?plan.json path required}"

# ── Validate ────────────────────────────────────────────────────────────────
jq -e '
  . as $all
  | (.items | type == "array" and length > 0 and length <= 20)
    and ([.items[].key] | length == (unique | length))
    and (.items | to_entries | all(
          .key as $i | (.value.depends_on // []) | all(. as $d |
            ([ $all.items[:$i][].key ] | index($d)) != null)))
' "$PLAN" >/dev/null || { log "invalid plan: needs 1-20 items, unique keys, deps on earlier keys only"; exit 1; }

existing="$(gh issue list --repo "$REPO" --label claude-subtask --state all --limit 500 --json body \
  -q "[.[] | select(.body | contains(\"<!-- claude-plan parent=${PARENT} \"))] | length")"
if [ "$existing" -gt 0 ]; then
  log "epic #$PARENT already has $existing planned sub-issues; refusing to create duplicates"
  exit 1
fi

# ── Create in order ─────────────────────────────────────────────────────────
NUM_BY_KEY="{}"   # JSON map key -> issue number (bash 3 compatible)
checklist=""
count="$(jq '.items | length' "$PLAN")"

for i in $(seq 0 $((count - 1))); do
  item="$(jq -c ".items[$i]" "$PLAN")"
  key="$(jq -r .key <<<"$item")"
  title="$(jq -r .title <<<"$item")"
  order=$((i + 1))

  dep_nums=()
  while read -r dk; do
    [ -n "$dk" ] && dep_nums+=("$(jq -r --arg k "$dk" '.[$k]' <<<"$NUM_BY_KEY")")
  done < <(jq -r '.depends_on // [] | .[]' <<<"$item")
  deps_csv="$(IFS=,; echo "${dep_nums[*]:-}")"
  deps_human="none — can start immediately"
  [ -n "$deps_csv" ] && deps_human="$(printf '#%s, ' "${dep_nums[@]}" | sed 's/, $//')"

  touches="$(jq -r '(.touches // []) | map("`" + . + "`") | join(", ")' <<<"$item")"
  body="$(jq -r .body <<<"$item" | defang)

---
**Parent:** #${PARENT} · **Step ${order} of ${count}** · **Depends on:** ${deps_human}
${touches:+**Expected to touch:** ${touches}}

_Planned by the Claude epic planner. This issue is labeled \`claude\` automatically once its dependencies are closed._
<!-- claude-plan parent=${PARENT} order=${order} depends=${deps_csv} -->"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    num=$((90000 + order))
    log "[dry-run] would create #$num: $title (depends: ${deps_csv:-none})"
  else
    url="$(gh issue create --repo "$REPO" --title "$title" --body "$body" --label claude-subtask)"
    num="${url##*/}"
    # Link as a native sub-issue (best effort — older GHES / missing permission is fine).
    id="$(gh api "repos/$REPO/issues/$num" -q .id)"
    gh api -X POST "repos/$REPO/issues/$PARENT/sub_issues" -F "sub_issue_id=$id" >/dev/null 2>&1 \
      || log "could not link #$num as a native sub-issue (continuing)"
  fi
  NUM_BY_KEY="$(jq -c --arg k "$key" --argjson n "$num" '.[$k] = $n' <<<"$NUM_BY_KEY")"
  checklist+="- [ ] #${num} — ${title}${deps_csv:+ _(after $(printf '#%s ' "${dep_nums[@]}" | sed 's/ $//'))_}"$'\n'
done

summary="$(jq -r '.summary // ""' "$PLAN" | defang)"
gh_write issue comment "$PARENT" --repo "$REPO" --body "### Plan approved — ${count} sub-issues created

${summary}

${checklist}
Items with no open dependencies start in parallel (max ${MAX_PARALLEL:-3} at a time). Each PR that merges closes its sub-issue and starts the next ready ones. Add \`claude-hold\` to any sub-issue to pause it."

gh_write issue edit "$PARENT" --repo "$REPO" --remove-label claude-plan-proposed --add-label claude-planned \
  || true
