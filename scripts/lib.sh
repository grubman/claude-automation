#!/usr/bin/env bash
# Shared helpers for the Claude automation scripts. Source it; don't execute it.
#
# DRY_RUN=1 makes every mutating `gh` call print instead of execute, so the
# scripts can be exercised locally against the real repo without side effects.

set -euo pipefail

: "${REPO:?REPO (owner/name) must be set}"

log() { printf '[%s] %s\n' "$(basename "$0")" "$*" >&2; }

# gh_write <gh args...> — run a mutating gh command, or print it under DRY_RUN.
gh_write() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '[dry-run] gh' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  gh "$@"
}

# Never let bot output mention the Claude trigger word: claude.yml fires on any
# comment containing it, which would loop. Inserts a zero-width space.
defang() { perl -pe 's/\@(claude)/\@\xE2\x80\x8B$1/gi'; }

# issue_labels <number> — newline-separated label names.
issue_labels() { gh issue view "$1" --repo "$REPO" --json labels -q '.labels[].name'; }

has_label() { issue_labels "$1" | grep -qx "$2"; }

sha12() {
  if command -v sha1sum >/dev/null 2>&1; then printf '%s' "$1" | sha1sum | cut -c1-12
  else printf '%s' "$1" | shasum | cut -c1-12; fi
}
