#!/usr/bin/env bash
# Handles `/approve` on an epic: recovers the plan embedded in the latest proposal
# comment, creates the sub-issues, and dispatches the ready ones. No Claude run needed.
#
# Usage: REPO=... GH_TOKEN=... DISPATCH_TOKEN=<PAT> approve-plan.sh <epic>

source "$(dirname "$0")/lib.sh"
DIR="$(dirname "$0")"

PARENT="${1:?epic number required}"
OUT="${RUNNER_TEMP:-/tmp}/approved-plan.json"

b64="$(gh api --paginate "repos/$REPO/issues/$PARENT/comments" \
  -q '.[] | select(.body | contains("<!-- claude-plan-json:")) | .body' |
  LC_ALL=C grep -o '<!-- claude-plan-json:[A-Za-z0-9+/=]*' | tail -n1 | sed 's/^<!-- claude-plan-json://')"

if [ -z "$b64" ]; then
  gh_write issue comment "$PARENT" --repo "$REPO" --body "I couldn't find a proposed plan on this issue to approve. Remove and re-add the epic label to re-plan."
  exit 1
fi

printf '%s' "$b64" | base64 -d | gunzip > "$OUT"
"$DIR/create-subissues.sh" "$PARENT" "$OUT"
GH_TOKEN="${DISPATCH_TOKEN:?}" "$DIR/dispatch-ready.sh" "$PARENT"
