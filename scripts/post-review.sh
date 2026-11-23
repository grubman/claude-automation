#!/usr/bin/env bash
# Renders the reviewer's .claude-out/review.json as ONE sticky PR comment, sets a
# review:* label, and — for claude/* PRs that aren't ready — starts a bounded auto-fix
# round by adding `claude-fix` (via PAT so claude.yml is triggered).
#
# Usage: REPO=... GH_TOKEN=... DISPATCH_TOKEN=<PAT> PR=<n> HEAD_SHA=... HEAD_REF=... \
#        CI_CONCLUSION=... RUN_URL=... post-review.sh <review.json>

source "$(dirname "$0")/lib.sh"

REVIEW="${1:?review.json path required}"
: "${PR:?}" "${HEAD_SHA:?}" "${HEAD_REF:?}"
MAX_FIX_ROUNDS="${MAX_FIX_ROUNDS:-2}"
MARK="<!-- claude-review"

# ── Previous sticky comment (for update-in-place + auto-fix round counter) ──
prev="$(gh api --paginate "repos/$REPO/issues/$PR/comments" \
  -q ".[] | select(.body | startswith(\"$MARK\")) | {id, body}" | jq -cs 'last // {}')"
prev_id="$(jq -r '.id // empty' <<<"$prev")"
rounds="$(jq -r '.body // ""' <<<"$prev" | grep -o 'rounds=[0-9]*' | head -n1 | cut -d= -f2 || true)"
rounds="${rounds:-0}"

# ── Verdict (with deterministic overrides) ──
if [ -s "$REVIEW" ] && jq -e '.verdict' "$REVIEW" >/dev/null 2>&1; then
  verdict="$(jq -r .verdict "$REVIEW")"
else
  verdict="error"
fi
case "${CI_CONCLUSION:-none}" in success|none|skipped|neutral|pending) ;; *) [ "$verdict" = "error" ] || verdict="blocked" ;; esac
if [ "$verdict" = "ready" ] && jq -e '[.findings[]? | select(.severity == "blocker" or .severity == "major")] | length > 0' "$REVIEW" >/dev/null; then
  verdict="needs-changes"
fi

case "$verdict" in
  ready)         head="✅ **Ready to merge**";        label="review:ready" ;;
  needs-changes) head="⚠️ **Merge after fixes**";     label="review:needs-changes" ;;
  blocked)       head="❌ **Do not merge**";          label="review:blocked" ;;
  *)             head="❔ **Automated review failed** — review manually"; label="" ;;
esac
case "${CI_CONCLUSION:-none}" in
  success) ci="✅ passed" ;; none|skipped) ci="➖ not needed" ;; pending) ci="⏳ still running" ;; *) ci="❌ ${CI_CONCLUSION}" ;;
esac

# ── Auto-fix decision (claude/* PRs only) ──
fix_note=""
is_claude_pr=0; [[ "$HEAD_REF" == claude/* ]] && [ "${AUTO_FIX:-1}" = 1 ] && is_claude_pr=1
held=0; gh pr view "$PR" --repo "$REPO" --json labels -q '.labels[].name' | grep -qx claude-hold && held=1
start_fix=0; needs_human=0
if [ "$is_claude_pr" = 1 ] && { [ "$verdict" = "needs-changes" ] || [ "$verdict" = "blocked" ]; }; then
  if [ "$held" = 1 ]; then
    fix_note="Auto-fix skipped: \`claude-hold\` is set."
  elif [ "$rounds" -lt "$MAX_FIX_ROUNDS" ]; then
    rounds=$((rounds + 1)); start_fix=1
    fix_note="🔧 Auto-fix round ${rounds}/${MAX_FIX_ROUNDS} started — Claude will push fixes to this branch. Add \`claude-hold\` to stop."
  else
    needs_human=1
    issue="$(gh pr view "$PR" --repo "$REPO" --json body -q .body | grep -Eio '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' | head -n1 | grep -o '[0-9]*$' || true)"
    who=""
    [ -n "$issue" ] && who="@$(gh issue view "$issue" --repo "$REPO" --json author -q .author.login) "
    fix_note="${who}auto-fix used its ${MAX_FIX_ROUNDS} rounds and the PR still isn't ready — needs a human look. Submit a review with **Request changes** (or add \`claude-fix\`) to send Claude another round."
  fi
elif [ "$is_claude_pr" = 1 ] && [ "$verdict" = "ready" ] && [ "$held" = 0 ] && [ "$rounds" = 0 ] &&
     [ "${AUTO_FIX_MINOR:-1}" = 1 ] && jq -e '(.findings // []) | length > 0' "$REVIEW" >/dev/null 2>&1; then
  # Ready, but with minor findings: one polish round. Only on the first review (rounds=0),
  # so a re-review that finds new nits doesn't loop; the PR stays mergeable meanwhile.
  rounds=1; start_fix=1
  n_minor="$(jq '(.findings // []) | length' "$REVIEW")"
  fix_note="🔧 Auto-fix started for ${n_minor} minor finding(s). It's mergeable as is; merge now to skip it, or add \`claude-hold\` to stop."
fi

# ── Render ──
if [ "$verdict" = "error" ]; then
  body_main="The reviewer didn't produce a result. See ${RUN_URL:-the workflow run}."
else
  body_main="$(jq -r --arg repo "$REPO" --arg sha "$HEAD_SHA" '
    def sev: {"blocker":"🔴","major":"🟠","minor":"🟡"}[.] // "•";
    def loc: if .file then
        "[`\(.file)\(if .line then ":\(.line)" else "" end)`](https://github.com/\($repo)/blob/\($sha)/\(.file)\(if .line then "#L\(.line)" else "" end))"
      else "" end;
    "**Risk:** \(.risk // "?") · **Scope matches issue:** \(.scope_match // "?")\n\n"
    + "> \(.bottom_line // "")\n\n"
    + ((.highlights // []) | map("- " + .) | join("\n"))
    + (if (.findings // []) | length > 0 then
        "\n\n<details" + (if ([.findings[] | select(.severity != "minor")] | length) > 0 then " open" else "" end)
        + "><summary>Findings (\(.findings | length))</summary>\n\n"
        + (.findings | sort_by({"blocker":0,"major":1,"minor":2}[.severity] // 3)
           | map("- \(.severity | sev) **\(.title)** \(loc)\n  \(.detail)") | join("\n"))
        + "\n\n</details>"
      else "\n\nNo findings." end)' "$REVIEW")"
fi

comment="${MARK} sha=${HEAD_SHA} rounds=${rounds} -->
### Bottom line: ${head}
**CI:** ${ci} · **Commit:** \`${HEAD_SHA:0:7}\`

$(printf '%s' "$body_main" | defang)
${fix_note:+
---
${fix_note}}

<sub>Automated review · [run](${RUN_URL:-}) · re-run with a \`/review\` comment</sub>"

if [ -n "$prev_id" ]; then
  gh_write api -X PATCH "repos/$REPO/issues/comments/$prev_id" -f body="$comment" >/dev/null
else
  gh_write pr comment "$PR" --repo "$REPO" --body "$comment" >/dev/null
fi

for l in review:ready review:needs-changes review:blocked review:needs-human; do
  gh_write pr edit "$PR" --repo "$REPO" --remove-label "$l" >/dev/null 2>&1 || true
done
[ -n "$label" ] && gh_write pr edit "$PR" --repo "$REPO" --add-label "$label" >/dev/null
[ "$needs_human" = 1 ] && gh_write pr edit "$PR" --repo "$REPO" --add-label review:needs-human >/dev/null

if [ "$start_fix" = 1 ]; then
  GH_TOKEN="${DISPATCH_TOKEN:?}" gh_write pr edit "$PR" --repo "$REPO" --add-label claude-fix >/dev/null
fi
log "PR #$PR: verdict=$verdict rounds=$rounds start_fix=$start_fix"
