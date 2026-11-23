#!/usr/bin/env bash
# Runs right after a Claude step. If that step stopped because the Claude usage limit
# (5-hour or weekly) was hit, it saves the run's progress so a later run can continue
# where this one stopped instead of starting over:
#   - the Claude session transcript (~/.claude/projects) + .claude-out/ → $RUNNER_TEMP/claude-pause/
#     (the workflow uploads that dir as artifact `claude-session-<run id>`)
#   - for code-writing runs (KIND=worker|fix): the whole working tree, committed on top
#     of HEAD and pushed to refs/claude-wip/<kind>-<n> (a custom ref: no CI, no deploys)
# It then labels the issue/PR `claude-paused` and records a marker comment that
# claude-unpause.yml uses to re-trigger the run after the limit resets.
#
# Env: REPO GH_TOKEN DISPATCH_TOKEN(PAT) KIND=worker|fix|plan|review|monitor NUMBER TRIGGER
#      RUN_ID CLAUDE_OUTCOME PREV_ATTEMPT(optional) MAX_RESUMES(optional, default 12)
# Outputs (GITHUB_OUTPUT): paused=0|1, gave_up=0|1

source "$(dirname "$0")/lib.sh"
: "${KIND:?}" "${RUN_ID:?}"
EXEC="${EXEC_FILE:-${RUNNER_TEMP:-/tmp}/claude-execution-output.json}"
MAX_RESUMES="${MAX_RESUMES:-12}"   # backoff 1,2,4,8,16,24h… ≈ 10 days: covers a weekly limit
out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }

# Each output is written exactly once, on the way out.
finish() { out "paused=$1"; out "gave_up=$2"; exit 0; }
if [ "${CLAUDE_OUTCOME:-failure}" = "success" ] || [ ! -s "$EXEC" ]; then finish 0 0; fi

# ── Was it the usage limit? Only look at the final messages, not tool output. ──
tail_text="$(jq -r '
  ([.[] | select(.type == "result")] | last | (.result // "") + " " + ((.errors // []) | tostring)),
  ([.[] | select(.type == "assistant")] | last | .message.content[]? | select(.type == "text") | .text)
' "$EXEC" 2>/dev/null | tail -c 2000 || true)"
if ! grep -Eiq 'usage limit|hit your (usage )?limit|limit (reached|will reset)|out of (extra )?usage|rate_limit_error' <<<"$tail_text"; then
  log "Claude step failed for a reason other than the usage limit"
  finish 0 0
fi
log "usage limit hit: $(tr '\n' ' ' <<<"$tail_text" | head -c 200)"

attempt=$(( ${PREV_ATTEMPT:-0} + 1 ))
session="$(jq -r '[.[] | select(.type == "system" and .subtype == "init")] | first | .session_id // empty' "$EXEC")"
now="$(date -u +%s)"

# ── When to retry: the reset time if the message has one, else exponential backoff. ──
reset=""
if epoch="$(grep -oE '\|[0-9]{10}' <<<"$tail_text" | head -n1 | tr -d '|')" && [ -n "$epoch" ]; then
  reset=$((epoch + 300))
elif t="$(grep -oEi 'resets( at)? [0-9]{1,2}(:[0-9]{2})? ?[ap]m' <<<"$tail_text" | head -n1 | sed -E 's/resets( at)? //I')" && [ -n "$t" ]; then
  tz="$({ grep -oE '\(([A-Za-z_]+/[A-Za-z_]+|UTC)\)' <<<"$tail_text" || true; } | head -n1 | tr -d '()')"   # message may omit the timezone
  if r="$(TZ="${tz:-UTC}" date -d "$t" +%s 2>/dev/null)"; then
    [ "$r" -gt "$now" ] || r=$((r + 86400))
    reset=$((r + 300))
  fi
fi
if [ -z "$reset" ]; then
  backoff=$(( 60 * (1 << (attempt - 1)) )); [ "$backoff" -le 1440 ] || backoff=1440
  reset=$((now + backoff * 60))
fi
reset_h="$(date -u -d "@$reset" '+%a %H:%M UTC' 2>/dev/null || date -u -r "$reset" '+%a %H:%M UTC')"

# Monitor runs just retry on the next scheduled sweep — new anomalies stay "new".
if [ "$KIND" = "monitor" ]; then finish 1 0; fi
: "${NUMBER:?}" "${TRIGGER:?}"

if [ "$attempt" -gt "$MAX_RESUMES" ]; then
  gh_write issue comment "$NUMBER" --repo "$REPO" --body "Hit the Claude usage limit again after ${MAX_RESUMES} resumes, so I'm giving up on automatic retries. The saved progress is in the last run's \`claude-session-*\` artifact and \`refs/claude-wip/${KIND}-${NUMBER}\`. Re-add \`${TRIGGER}\` to try again."
  gh_write issue edit "$NUMBER" --repo "$REPO" --remove-label claude-paused --add-label claude-failed || true
  finish 0 1
fi

# ── Save progress ──
dir="${RUNNER_TEMP:-/tmp}/claude-pause"; mkdir -p "$dir"
[ -d "$HOME/.claude/projects" ] && tar czf "$dir/transcripts.tgz" -C "$HOME" .claude/projects
[ -d .claude-out ] && tar czf "$dir/claude-out.tgz" .claude-out

branch=""; base=""
if [ "$KIND" = "worker" ] || [ "$KIND" = "fix" ]; then
  branch="$(git branch --show-current || true)"
  base="$(git rev-parse HEAD)"
  git config user.name  >/dev/null || git config user.name  "github-actions[bot]"
  git config user.email >/dev/null || git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add -A -- . ':!.github/workflows' ':!**/.env*'
  git commit -q --allow-empty --no-verify -m "wip: paused by usage limit (run ${RUN_ID})"
  [ "${GITHUB_ACTIONS:-}" != "true" ] || git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git"
  gh_write_git() { if [ "${DRY_RUN:-0}" = "1" ]; then log "[dry-run] git $*"; else git "$@"; fi; }
  gh_write_git push -q -f origin "HEAD:refs/claude-wip/${KIND}-${NUMBER}"
fi

gh_write issue comment "$NUMBER" --repo "$REPO" --body "⏸️ Paused: the Claude usage limit was reached mid-run (attempt ${attempt}/${MAX_RESUMES}). Progress is saved and the run will **resume automatically after ~${reset_h}**, continuing the same session.
Remove \`claude-paused\` and re-add \`${TRIGGER}\` to resume sooner, or add \`claude-hold\` to stop.
<!-- claude-paused kind=${KIND} run=${RUN_ID} session=${session} reset=${reset} attempt=${attempt} trigger=${TRIGGER} branch=${branch} base=${base} state=waiting -->"
gh_write issue edit "$NUMBER" --repo "$REPO" --add-label claude-paused
# Arm the (otherwise skipped, zero-minute) hourly unpause job.
GH_TOKEN="${DISPATCH_TOKEN:-$GH_TOKEN}" gh_write variable set CLAUDE_PAUSED --repo "$REPO" --body 1 \
  || log "could not set CLAUDE_PAUSED (PAT needs Variables: write) — resume manually"
finish 1 0
