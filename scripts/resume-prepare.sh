#!/usr/bin/env bash
# Runs before a Claude step. If an earlier run of the same kind on this issue/PR was
# paused by the usage limit, restores its progress so Claude continues instead of
# starting over: working tree (worker/fix), .claude-out/, and the session transcript
# (the workflow downloads artifact `claude-session-<run>` into $RESTORE_DIR first —
# see the "resume" step pair in the workflows).
#
# Phase 1 (PHASE=find):    outputs resume=1 run=<id> attempt=<n> when a marker is pending.
# Phase 2 (PHASE=restore): restores files, outputs args (extra claude_args) and prefix (prompt).
#
# Env: REPO GH_TOKEN KIND NUMBER PHASE RESTORE_DIR(restore) RESUME_* (restore, from phase 1)

source "$(dirname "$0")/lib.sh"
: "${KIND:?}" "${NUMBER:?}" "${PHASE:?}"
out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; return 0; }
field() { { grep -o " $1=[^ ]*" <<<"$2" || true; } | head -n1 | cut -d= -f2-; }   # no match → empty, not a pipefail exit

if [ "$PHASE" = "find" ]; then
  # Latest pause marker of this kind that hasn't been consumed yet.
  c="$(gh api --paginate "repos/$REPO/issues/$NUMBER/comments" \
        -q ".[] | select(.body | contains(\"<!-- claude-paused kind=${KIND} \")) | {id, body}" | jq -cs 'last // {}')"
  marker="$(jq -r '.body // ""' <<<"$c" | grep -o '<!-- claude-paused [^>]*-->' | tail -n1 || true)"
  state="$(field state "$marker")"
  if [ -z "$marker" ] || [ "$state" = "consumed" ]; then out "resume=0"; exit 0; fi
  id="$(jq -r .id <<<"$c")"
  # Consume it now, so a later unrelated run never resumes a stale session.
  new_body="$(jq -r .body <<<"$c" | sed "s/ state=${state} -->/ state=consumed -->/")"
  gh_write api -X PATCH "repos/$REPO/issues/comments/$id" -f body="$new_body" >/dev/null
  for k in run session attempt branch base; do out "$k=$(field "$k" "$marker")"; done
  out "resume=1"
  log "resuming $KIND #$NUMBER from run $(field run "$marker") (attempt $(field attempt "$marker"))"
  exit 0
fi

# ── PHASE=restore ──
: "${RESTORE_DIR:?}"
restored=()
if { [ "$KIND" = "worker" ] || [ "$KIND" = "fix" ]; } && git fetch -q origin "refs/claude-wip/${KIND}-${NUMBER}" 2>/dev/null; then
  wip="$(git rev-parse FETCH_HEAD)"
  if [ -n "${RESUME_BRANCH:-}" ]; then git checkout -q -B "$RESUME_BRANCH" "${wip}~1"; else git checkout -q --detach "${wip}~1"; fi
  patch="$(mktemp)"; git diff --binary "${wip}~1" "$wip" > "$patch"
  [ -s "$patch" ] && git apply "$patch"   # uncommitted edits come back as uncommitted
  # The wip ref is deleted only after a successful run (see "Clean up WIP ref").
  restored+=("working tree on ${RESUME_BRANCH:-detached HEAD}")
fi
if [ -f "$RESTORE_DIR/claude-out.tgz" ]; then tar xzf "$RESTORE_DIR/claude-out.tgz"; restored+=(".claude-out/"); fi
args=""
if [ -f "$RESTORE_DIR/transcripts.tgz" ]; then
  tar xzf "$RESTORE_DIR/transcripts.tgz" -C "$HOME"
  if [ -n "${RESUME_SESSION:-}" ] && ls "$HOME"/.claude/projects/*/"${RESUME_SESSION}.jsonl" >/dev/null 2>&1; then
    args="--resume ${RESUME_SESSION}"; restored+=("session ${RESUME_SESSION}")
  fi
fi
log "restored: ${restored[*]:-nothing}"
out "args=$args"
delim="P_$(openssl rand -hex 6)"
{
  echo "prefix<<${delim}"
  echo "RESUMED RUN: a previous run on this task stopped because the Claude usage limit was reached."
  echo "Restored: ${restored[*]:-nothing (start over, but check git branches and .claude-out/ first)}."
  echo "Continue from where you left off — check \`git status\`, \`git log -3\` and .claude-out/notes.md"
  echo "before redoing anything. The original instructions follow."
  echo
  echo "${delim}"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
