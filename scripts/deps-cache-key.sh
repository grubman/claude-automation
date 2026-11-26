#!/usr/bin/env bash
# Prints `key=claude-deps-<hash>` to $GITHUB_OUTPUT for the worker's installed-dependencies cache.
# Shared by worker.yml (restore) and deps-cache.yml (warm), so both always compute the same key.
# Env: KEY_FILES (newline-separated git pathspecs), SETUP (the setup command).
# Run from the repository checkout, after setup-node (the Node version is part of the key).
set -euo pipefail
mapfile -t pats < <(printf '%s\n' "${KEY_FILES:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d')
[ "${#pats[@]}" -gt 0 ] || { echo "No key files: cache disabled"; exit 0; }
# git ls-files -s lists each tracked file's blob hash, so the key changes with content.
h=$( { printf '%s\n' "${SETUP:-}" "$RUNNER_OS" "$(node --version 2>/dev/null || true)"; git ls-files -s -- "${pats[@]}"; } \
  | sha256sum | cut -c1-40)
echo "key=claude-deps-$h" >> "$GITHUB_OUTPUT"
echo "Dependency cache key: claude-deps-$h"
