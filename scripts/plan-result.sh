#!/usr/bin/env bash
# Acts on the planner's output file (.claude-out/plan.json).
#
#   status == "needs_input" → ask the epic author the blocking questions, label claude-needs-input
#   status == "proposed"    → AUTO=1: create sub-issues + dispatch right away
#                             AUTO=0: post the plan for approval, label claude-plan-proposed
#
# Usage: REPO=... GH_TOKEN=... DISPATCH_TOKEN=<PAT> AUTO=0|1 AUTHOR=<login> plan-result.sh <epic> <plan.json>

source "$(dirname "$0")/lib.sh"
DIR="$(dirname "$0")"

PARENT="${1:?epic number required}"
PLAN="${2:?plan.json path required}"
AUTHOR="${AUTHOR:?epic author login required}"

if [ ! -s "$PLAN" ] || ! jq -e . "$PLAN" >/dev/null 2>&1; then
  gh_write issue comment "$PARENT" --repo "$REPO" --body "The epic planner finished without producing a valid plan. See ${RUN_URL:-the workflow run}. Remove and re-add the epic label to retry."
  exit 1
fi

status="$(jq -r .status "$PLAN")"

case "$status" in
  needs_input)
    questions="$(jq -r '.questions | to_entries | map("\(.key + 1). \(.value.q)\n   _Default if you don'"'"'t care:_ \(.value.default)") | join("\n")' "$PLAN" | defang)"
    gh_write issue comment "$PARENT" --repo "$REPO" --body "@${AUTHOR} before I break this epic down I need a few answers:

${questions}

Reply in a comment here (one line per number is fine). Your reply restarts the planner automatically."
    gh_write issue edit "$PARENT" --repo "$REPO" --add-label claude-needs-input
    ;;

  proposed)
    if [ "${AUTO:-0}" = "1" ]; then
      "$DIR/create-subissues.sh" "$PARENT" "$PLAN"
      GH_TOKEN="${DISPATCH_TOKEN:?}" "$DIR/dispatch-ready.sh" "$PARENT"
      exit 0
    fi

    # Render the proposal; embed the machine-readable plan (gzip+base64, so it can't break
    # the HTML comment) so /approve can create exactly what was reviewed.
    rendered="$(jq -r '
      . as $p
      | ($p.items | to_entries | map({(.value.key): (.key + 1)}) | add) as $idx
      | ($p.items | to_entries | map(
          "\(.key + 1). **\(.value.title)**"
          + (if (.value.depends_on // []) | length > 0
               then " — after " + ((.value.depends_on) | map("step \($idx[.])") | join(", "))
               else " — _can start immediately_" end)
          + (if (.value.touches // []) | length > 0
               then "\n   <sub>" + ((.value.touches) | map("`" + . + "`") | join(" ")) + "</sub>" else "" end)
        ) | join("\n"))' "$PLAN" | defang)"
    assumptions="$(jq -r '(.assumptions // []) | map("- " + .) | join("\n")' "$PLAN" | defang)"
    summary="$(jq -r '.summary // ""' "$PLAN" | defang)"
    details="$(jq -r '.items | to_entries | map("<details><summary>\(.key + 1). \(.value.title)</summary>\n\n\(.value.body)\n\n</details>") | join("\n")' "$PLAN" | defang)"
    b64="$(jq -c . "$PLAN" | gzip -9c | base64 | tr -d '\n')"   # gzip: comments cap at 64KB

    compose() {  # $1 = per-item details block (may be empty)
      printf '%s' "### Proposed breakdown

${summary}

${rendered}

${assumptions:+**Assumptions:**
${assumptions}
}
$1

---
@${AUTHOR} reply **\`/approve\`** to create these sub-issues and start the independent ones in parallel, or reply with changes and I'll re-plan.
<!-- claude-plan-json:${b64} -->"
    }
    body="$(compose "$details")"
    # GitHub comments cap at 65536 chars: drop the expanded item bodies if needed.
    [ "${#body}" -lt 64000 ] || body="$(compose "_Item details omitted (too long for one comment); they will be in each sub-issue._")"
    gh_write issue comment "$PARENT" --repo "$REPO" --body "$body"
    gh_write issue edit "$PARENT" --repo "$REPO" --add-label claude-plan-proposed
    ;;

  *)
    log "unknown planner status: $status"
    exit 1
    ;;
esac
