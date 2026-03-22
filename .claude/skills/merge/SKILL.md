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
   - **CI agent:** Run `gh pr checks` and wait for all checks to pass. If any check is still pending, poll every 30 seconds (up to 5 minutes). If a check fails, stop and report the failure.
   - **Codex agent:** Check all three comment endpoints:
     - `gh api repos/{owner}/{repo}/issues/{number}/comments` — **this is where Codex posts**
     - `gh api repos/{owner}/{repo}/pulls/{number}/comments` — inline review comments
     - `gh api repos/{owner}/{repo}/pulls/{number}/reviews` — review bodies
     Wait up to 5 minutes for comments to arrive (poll every 60 seconds). Rules:
     - If Codex comments are only about **quota being over**, ignore them — that's fine.
     - If Codex has **bugfix or actionable comments**, address them by default — fix the issues, commit, and push. Only ask the user if the fix is unclear or contentious.
     - If there are **no comments** after 5 minutes, note this so the user can check manually.

Both agents MUST run in parallel (launched in a single message with two Agent tool calls). **Report results as they arrive** — don't wait for both to finish. If Codex has actionable comments, address them immediately (even if CI is still pending — CI will re-run after the fix push anyway). Only proceed to Phase 2 once both are resolved.

### Phase 2: Merge (foreground, needs user)

4. Report the Phase 1 results (CI status, any Codex comments found/addressed).
5. If CI failed, stop — do NOT merge.
6. If there were unresolved Codex comments, ask the user what to do.
7. If Codex only posted a **quota-exceeded** message (no actual review), treat it the same as "no actionable comments" — proceed to merge without asking.
8. If **no comments arrived at all** after polling, tell the user and **wait for explicit confirmation** before merging. Do NOT run the merge command until the user says to proceed — they may want to check Codex manually first.
9. **Merge:** Only after user confirms (or after quota-only Codex result). Run `gh pr merge --merge` (not squash, not rebase). The guard-pr-merge hook will ask the user for confirmation — that's expected.
10. **Cleanup:** Switch back to `main` and pull latest.
11. Report the merge result.

## Rules

- Do NOT merge if CI has failed.
- Do NOT skip the Codex comment check — always wait or ask.
- Do NOT force merge or use `--admin`.
- Phase 1 MUST run in background so the user can do other work while waiting.
