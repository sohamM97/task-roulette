---
name: merge-check
description: Check CI & reviews, then merge PR. Use when the user wants to merge a PR.
---

# Merge Pull Request

Merge the current branch's PR after verifying CI and review comments.

**Arguments:** `$ARGUMENTS` (optional: PR number. If not provided, detect from current branch.)

## Workflow

### Phase 1: Checks (run in background)

1. Identify the PR — use `$ARGUMENTS` if provided, otherwise run `gh pr view --json number` from the current branch.
2. Launch **two background agents in parallel**:
   - **CI agent:** Run `gh pr checks` and wait for **all** checks to pass (including `analyze-and-test`, `claude-review`, and any other checks). If any check is still pending, poll every 30 seconds (up to **30 minutes** — `claude-review` can take 25+ minutes on large PRs). If a check fails, stop and report the failure. Checks with status `skipping` can be ignored. **Note:** `claude-review` and `codex` are independent review bots — do NOT conflate them. `claude-review` is a GitHub Actions check that posts comments; `codex` (chatgpt-codex-connector[bot]) is a separate bot. One being over quota does NOT mean the other won't run.
   - **Review comments agent:** First wait for the `claude-review` CI check to complete (poll `gh pr checks {number}` every 30 seconds until `claude-review` shows `pass` or `fail` — up to **30 minutes**). Only AFTER `claude-review` has completed, check all three comment endpoints for comments from **any bot** (Codex, Claude, or other reviewers) **on this specific PR number only** — do NOT look at GitHub Actions run history or other PRs:
     - `gh api repos/{owner}/{repo}/issues/{number}/comments` — where Codex posts review summaries and Claude posts review bodies
     - `gh api repos/{owner}/{repo}/pulls/{number}/comments` — inline review comments (both Codex and Claude post here)
     - `gh api repos/{owner}/{repo}/pulls/{number}/reviews` — review bodies
     After reading the endpoints, if no `claude[bot]` comments are found yet, poll these endpoints 3 more times at 30-second intervals (claude-review may post comments slightly after the CI check completes). Rules:
     - If bot comments are only about **quota being over**, ignore them — that's fine.
     - If any reviewer has **bugfix or actionable comments** (look for P0/P1/P2 labels, specific code suggestions, or bug reports), address them by default — fix the issues, commit, and push. Only ask the user if the fix is unclear or contentious.
     - If a review completed with **no inline comments** (e.g. Claude's `"No buffered inline comments"`), that's a clean review — no action needed.
     - If there are **no comments** after the CI check completed and polling, note this so the user can check manually.
     - **CRITICAL:** Do NOT conclude "no review comments" while `claude-review` CI is still pending or running. The review comments are posted by the CI job — they cannot exist until the job finishes.

Both agents MUST run in parallel (launched in a single message with two Agent tool calls). **Report results as they arrive** — don't wait for both to finish. If any reviewer has actionable comments, address them immediately (even if CI is still pending — CI will re-run after the fix push anyway). Only proceed to Phase 2 once both are resolved.

**IMPORTANT: When reporting agent results, verify current state first.** Background agents return point-in-time snapshots that may be stale by the time you present them. Before reporting, run `gh pr checks <number>` to get live status — do NOT relay an agent's "still pending" if the check has since completed.

### Phase 2: Merge (foreground, needs user)

4. Report the Phase 1 results (CI status, any review comments found/addressed). Always use **live status** from `gh pr checks`, not cached agent output.
5. If CI failed, stop — do NOT merge.
6. If there were unresolved review comments, ask the user what to do.
7. If bot reviewers only posted a **quota-exceeded** message (no actual review), treat it the same as "no actionable comments" — proceed to merge without asking.
8. If **no comments arrived at all** after polling, tell the user and **wait for explicit confirmation** before merging. Do NOT run the merge command until the user says to proceed — they may want to check manually first.
9. **Merge:** Only after user confirms (or after clean/quota-only review result). Run `gh pr merge --merge --delete-branch` (not squash, not rebase). This deletes the remote branch after merge. The guard-pr-merge hook will ask the user for confirmation — that's expected.
10. **Cleanup:** Switch back to `main`, pull latest, and delete the local branch (`git branch -d <branch>`). Note: `--delete-branch` already deletes the local branch if the merge fast-forwards — use `git branch -d` only if the branch still exists (ignore errors if already deleted).
11. Report the merge result.

## Rules

- Do NOT merge if CI has failed.
- Do NOT skip the review comment check — always wait or ask.
- Do NOT force merge or use `--admin`.
- Phase 1 MUST run in background so the user can do other work while waiting.
