#!/usr/bin/env bash
# Collects deterministic facts about a PR for the reviewer (no LLM): CI verdict and
# failure logs, changed files, guardrail flags, linked issue. Prints Markdown to stdout.
#
# Usage: REPO=... GH_TOKEN=... PR=<n> BASE=<branch> CI_CONCLUSION=<success|failure|...|none> \
#        CI_RUN_ID=<id or empty> [PROJECT_CHECKS=<file>] [SRC_REGEX=<ere>] pr-facts.sh
# Expects the PR head checked out with full history and origin/$BASE fetched.
#
# PROJECT_CHECKS: optional bash file with repo-specific checks. It is sourced, and can use
#   $range, $files, $added_lines and call `flag <BLOCKER|MAJOR|MINOR> "<text>"`.
#   The workflow takes it from the BASE branch, so a PR can't change the checks it's judged by.

source "$(dirname "$0")/lib.sh"

: "${PR:?}" "${BASE:=main}"
: "${SRC_REGEX:=^(backend|frontend|src|app|lib|packages)/}"
range="origin/${BASE}...HEAD"

files="$(git diff --name-only "$range")"
added_lines="$(git diff -U0 "$range" | grep -E '^\+[^+]' || true)"

n=0
flag() { printf -- '- **%s** %s\n' "$1" "$2"; n=$((n+1)); }

echo "# PR facts (deterministic pre-checks)"
echo
echo "## CI"
case "${CI_CONCLUSION:-none}" in
  success) echo "CI passed (run ${CI_RUN_ID})." ;;
  none)    echo "CI did not run for this PR (no files its checks cover)." ;;
  pending) echo "CI is still running (run ${CI_RUN_ID}); judge the code only." ;;
  *)       echo "CI conclusion: **${CI_CONCLUSION}** (run ${CI_RUN_ID})."
           if [ -n "${CI_RUN_ID:-}" ]; then
             echo; echo '<details><summary>Failed step log (tail)</summary>'; echo; echo '```'
             gh run view "$CI_RUN_ID" --repo "$REPO" --log-failed 2>/dev/null | tail -n 150 | cut -c1-300 || echo "(log unavailable)"
             echo '```'; echo '</details>'
           fi ;;
esac

echo
echo "## Diff"
echo '```'
git diff --stat "$range" | tail -n 40
echo '```'

echo
echo "## Guardrail flags"
if grep -q '^\.github/workflows/' <<<"$files"; then flag BLOCKER "modifies \`.github/workflows/\` (forbidden for the automated agent)"; fi
if grep -E '(^|/)\.env($|\.)' <<<"$files" | grep -vq '\.example$'; then
  flag BLOCKER "adds/changes a \`.env\` file"; fi
if grep -Eiq '(AccountKey=|Password=[^;$ ]{4,}|-----BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-ant-[A-Za-z0-9_-]{20,}|xox[bp]-[A-Za-z0-9-]{20,})' <<<"$added_lines"; then
  flag BLOCKER "added lines look like a secret / connection string"; fi
src_changed="$({ grep -E "$SRC_REGEX" <<<"$files" || true; } | grep -Ev '(__tests__|\.test\.|\.spec\.|/tests?/|\.md$)' || true)"
tests_changed="$(grep -E '(__tests__|\.test\.|\.spec\.|/tests?/|/e2e/)' <<<"$files" || true)"
if [ -n "$src_changed" ] && [ -z "$tests_changed" ]; then
  flag MINOR "source files changed but no test files changed"; fi
if [ -n "${PROJECT_CHECKS:-}" ] && [ -s "$PROJECT_CHECKS" ]; then
  # shellcheck source=/dev/null
  source "$PROJECT_CHECKS" || echo "- (project checks failed to run: exit $?)"
fi
[ "$n" -eq 0 ] && echo "None."

echo
echo "## Linked issue"
body="$(gh pr view "$PR" --repo "$REPO" --json body -q .body)"
issue="$({ grep -Eio '(close[sd]?|fix(e[sd])?|resolve[sd]?) #[0-9]+' <<<"$body" || true; } | head -n1 | grep -o '[0-9]*$' || true)"
if [ -n "$issue" ]; then
  echo "#${issue}:"
  echo
  gh issue view "$issue" --repo "$REPO" --json title,body -q '"### " + .title + "\n\n" + .body' | head -c 6000
else
  echo "None referenced in the PR body."
fi
