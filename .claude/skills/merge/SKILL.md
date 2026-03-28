---
name: merge
description: Merge Pull Request. Use when the user wants to merge a PR.
---

# Merge Pull Request

Merge the current branch's PR after verifying CI and review comments.

**Arguments:** `$ARGUMENTS` (optional: PR number. If not provided, detect from current branch.)

## Workflow

### Phase 1: Checks (run in background)

1. Identify the PR — use `$ARGUMENTS` if provided, otherwise run `gh pr view --json number` from the current branch.
2. Launch **two background agents in parallel**:
   - **CI agent:** Run `gh pr checks` and wait for **all** checks to pass (including `analyze-and-test`, `claude-review`, and any other checks). If any check is still pending, poll every 30 seconds (up to 5 minutes). If a check fails, stop and report the failure. Checks with status `skipping` can be ignored.
   - **Review comments agent:** Check all three comment endpoints for comments from **any bot** (Codex, Claude, or other reviewers) **on this specific PR number only** — do NOT look at GitHub Actions run history or other PRs:
     - `gh api repos/{owner}/{repo}/issues/{number}/comments` — where Codex posts review summaries
     - `gh api repos/{owner}/{repo}/pulls/{number}/comments` — inline review comments (both Codex and Claude post here)
     - `gh api repos/{owner}/{repo}/pulls/{number}/reviews` — review bodies
     Wait up to 5 minutes for comments to arrive (poll every 60 seconds). Rules:
     - If bot comments are only about **quota being over**, ignore them — that's fine.
     - If any reviewer has **bugfix or actionable comments** (look for P0/P1/P2 labels, specific code suggestions, or bug reports), address them by default — fix the issues, commit, and push. Only ask the user if the fix is unclear or contentious.
     - If a review completed with **no inline comments** (e.g. Claude's `"No buffered inline comments"`), that's a clean review — no action needed.
     - If there are **no comments** after 5 minutes, note this so the user can check manually.

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
