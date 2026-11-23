#!/usr/bin/env bash
# Hourly (claude-unpause.yml): for every open issue/PR labeled `claude-paused` whose
# reset time has passed, re-trigger the paused flow. The re-triggered run finds the
# pause marker and resumes the saved session (resume-prepare.sh).
# When nothing is paused any more, disarms the hourly job (CLAUDE_PAUSED=0).
#
# Env: REPO GH_TOKEN(PAT: issues, pull requests, actions, variables write)

source "$(dirname "$0")/lib.sh"
now="$(date -u +%s)"
field() { { grep -o " $1=[^ ]*" <<<"$2" || true; } | head -n1 | cut -d= -f2-; }   # no match → empty, not a pipefail exit

# Issues API lists open issues AND PRs by label (search/issues now requires is:issue/is:pr).
nums="$(gh api --paginate "repos/${REPO}/issues?state=open&labels=claude-paused&per_page=100" -q '.[].number')"
remaining=0
for n in $nums; do
  labels="$(gh api "repos/$REPO/issues/$n" -q '.labels[].name')"
  if grep -qx claude-hold <<<"$labels"; then log "#$n on hold"; remaining=$((remaining + 1)); continue; fi
  marker="$(gh api --paginate "repos/$REPO/issues/$n/comments" -q '.[].body' |
            grep -o '<!-- claude-paused [^>]*state=waiting -->' | tail -n1 || true)"
  if [ -z "$marker" ]; then
    log "#$n has no pending marker; clearing claude-paused"
    gh_write issue edit "$n" --repo "$REPO" --remove-label claude-paused; continue
  fi
  reset="$(field reset "$marker")"; trigger="$(field trigger "$marker")"
  if [ "$now" -lt "${reset:-0}" ]; then
    log "#$n waits until $(date -u -d "@$reset" +%FT%TZ 2>/dev/null || echo "$reset")"
    remaining=$((remaining + 1)); continue
  fi
  log "#$n: limit reset passed, re-triggering via ${trigger}"
  gh_write issue edit "$n" --repo "$REPO" --remove-label claude-paused
  if [ "$trigger" = "review" ]; then
    gh_write workflow run claude-review.yml --repo "$REPO" -f pr="$n"
  else
    gh_write issue edit "$n" --repo "$REPO" --remove-label "$trigger" || true
    gh_write issue edit "$n" --repo "$REPO" --add-label "$trigger"
  fi
done

if [ "$remaining" -eq 0 ]; then
  gh_write variable set CLAUDE_PAUSED --repo "$REPO" --body 0
fi
log "$remaining paused item(s) still waiting"
