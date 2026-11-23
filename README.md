# claude-automation

Shared GitHub Actions for an agentic development flow built on
[`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action).
Each project repo keeps only thin caller workflows; the logic, scripts and prompts live here.

| Reusable workflow | What it does |
|---|---|
| `.github/workflows/review.yml` | Reviews every non-draft PR after CI and posts one sticky **Bottom line** comment (✅ / ⚠️ / ❌) plus a `review:*` label. On `claude/*` PRs that aren't ready, starts bounded auto-fix rounds. |

More workflows (worker, epic planner, dispatcher, resume, live-site monitor) are being moved here.

## Using it in a repo
1. Copy `examples/claude-review.yml` to `.github/workflows/claude-review.yml` and set the
   CI workflow names, files and paths.
2. Secrets (Settings → Secrets and variables → Actions):
   - `CLAUDE_CODE_OAUTH_TOKEN`: from `claude setup-token`.
   - `AUTOMATION_PAT` (optional for review, needed for auto-fix): a fine-grained token for
     that repo with read/write on Contents, Issues, Pull requests and Actions, and Variables: write.
     Labels and comments made with the job token don't trigger other workflows, so the
     automation uses this token where it has to start another run.
3. Labels: `REPO=owner/name bash scripts/setup-labels.sh`
4. Project knowledge stays in the repo:
   - `CLAUDE.md`: architecture, rules and the verification commands. The prompts read it.
   - `.github/claude/checks.sh` (optional): extra deterministic flags for the reviewer.
     It's sourced by `scripts/pr-facts.sh` and can call `flag MAJOR "text"` using
     `$files`, `$added_lines` and `$range`.
   - `.github/claude/review-extra.md` (optional): extra review rules.
   Both are read from the PR's base branch, so a PR can't change what it's judged by.

## Versioning
Callers pin a tag (`@v1`) and the workflow loads scripts from the same tag
(`automation_ref`, default `v1`). Changes land on `main`; move the tag when they're ready.
