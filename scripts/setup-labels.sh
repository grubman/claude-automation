#!/usr/bin/env bash
# One-time: create/update every label the Claude automation uses. Safe to re-run.
# Usage: REPO=owner/name bash scripts/setup-labels.sh
set -euo pipefail
: "${REPO:=$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

while IFS='|' read -r name color desc; do
  [ -n "$name" ] || continue
  gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force
done <<'EOF'
claude|D97757|Hand this issue to the Claude Auto-PR workflow
claude-epic|B35A3F|Claude breaks this issue into ordered sub-issues (asks you to /approve the plan)
claude-epic-auto|B35A3F|Like claude-epic, but creates and starts sub-issues without approval
claude-subtask|F2C1A9|Sub-issue planned by the Claude epic planner
claude-planned|F2C1A9|Epic whose plan was approved and turned into sub-issues
claude-plan-proposed|FBCA04|Claude proposed a plan — reply /approve or with changes
claude-needs-input|FBCA04|Claude is waiting for your answer — just reply in a comment
claude-failed|B60205|Claude run produced no PR — remove this label (or re-add claude) to retry
claude-paused|C5DEF5|Hit the Claude usage limit — progress saved, resumes automatically after reset
claude-hold|5319E7|Pause all Claude automation on this issue/PR
claude-fix|D97757|Claude pushes fixes for the latest review / CI failures to this PR
review:ready|0E8A16|Automated review: ready to merge
review:needs-changes|FBCA04|Automated review: merge after fixes
review:blocked|B60205|Automated review: do not merge
review:needs-human|5319E7|Auto-fix rounds exhausted — needs a human look
monitoring|1D76DB|Opened by the live-site monitor
monitoring-suppressed|C5DEF5|Signals the live-site monitor ignores
EOF
