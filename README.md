# claude-automation

Shared GitHub Actions for an agentic development flow built on
[`anthropics/claude-code-action`](https://github.com/anthropics/claude-code-action).
Each project repo keeps only thin caller workflows (`examples/`); the logic, scripts and
prompts live here.

| Reusable workflow | Caller (keep the name) | What it does |
|---|---|---|
| `worker.yml` | `claude.yml` | Issue labeled `claude` → builds it on `claude/issue-<n>-<slug>` and opens a PR. On a PR (Claude mention, "Request changes" on a `claude/*` PR, or `claude-fix` label) → pushes fixes to the same branch. |
| `review.yml` | `claude-review.yml` | Reviews every non-draft PR after CI; posts one sticky **Bottom line** (✅ / ⚠️ / ❌) and a `review:*` label. Starts bounded auto-fix rounds on `claude/*` PRs. |
| `plan.yml` | `claude-plan.yml` | Issue labeled `claude-epic` → proposes ordered, PR-sized sub-issues; `/approve` creates them. `claude-epic-auto` skips the approval. |
| `dispatch.yml` | `claude-dispatch.yml` | When a sub-issue closes, labels the next ready ones `claude` (capped in parallel); closes the epic when all are done. |
| `resume.yml` | `claude-resume.yml` | When Claude asked a question (`claude-needs-input` / `claude-plan-proposed`), your reply re-runs the right flow. |
| `unpause.yml` | `claude-unpause.yml` | Runs paused by the Claude usage limit resume automatically after the reset. |

Safety nets: `claude-hold` stops anything; agents never push to the default branch, edit
`.github/workflows/`, or commit secrets; reviews never run on fork PRs.

## Setting up a repo
1. Copy the callers you want from `examples/` to `.github/workflows/` and adjust the marked
   lines (CI workflow names and paths for the review; Node and install command for the worker).
   Keep the file names: scripts re-trigger `claude-review.yml` by name.
2. Install the [Claude GitHub App](https://github.com/apps/claude) on the repo.
3. Secrets (Settings → Secrets and variables → Actions):
   - `CLAUDE_CODE_OAUTH_TOKEN`: from `claude setup-token`.
   - `AUTOMATION_PAT`: a fine-grained token for the repo's owner with read/write on Contents,
     Issues, Pull requests, Actions and Variables. Labels and comments made with the job token
     don't trigger other workflows, so the automation uses this token where it has to start
     another run. Required for the planner, dispatcher, resume, unpause and auto-fix.
   Set secrets in the web UI; `gh secret set` without a terminal stores an empty value.
4. Labels: `REPO=owner/name bash scripts/setup-labels.sh`
5. Project knowledge stays in the repo:
   - `CLAUDE.md`: architecture, rules, and the verification commands every agent must run.
   - `.github/claude/checks.sh` (optional): extra deterministic reviewer flags, sourced by
     `scripts/pr-facts.sh`; call `flag MAJOR "text"` using `$files`, `$added_lines`, `$range`.
   - `.github/claude/review-extra.md` (optional): extra review rules.
   - `.github/claude/plan-extra.md` (optional): extra planning rules (e.g. which paths must
     be serialized, design-guide requirements).
   The reviewer reads `checks.sh` and `review-extra.md` from the PR's base branch, so a PR
   can't change what it's judged by.

## Versioning
Callers pin a tag (`@v1`) and each workflow loads its scripts from the same tag
(`automation_ref`, default `v1`). Changes land on `main`; move the tag when they're ready.
