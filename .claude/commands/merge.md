# Merge Pull Request

Merge the current branch's PR after verifying CI and review comments.

**Arguments:** `$ARGUMENTS` (optional: PR number. If not provided, detect from current branch.)

## Workflow

1. Identify the PR — use `$ARGUMENTS` if provided, otherwise run `gh pr view --json number` from the current branch.
2. **CI check (mandatory):** Run `gh pr checks` and wait for all checks to pass. If any check is still pending, poll every 30 seconds (up to 5 minutes). If a check fails, stop and report the failure — do NOT merge.
3. **Codex review comments:** Run `gh api repos/{owner}/{repo}/pulls/{number}/comments` to check for review comments. Also check `gh api repos/{owner}/{repo}/pulls/{number}/reviews` for review bodies.
   - Wait up to 5 minutes for Codex comments to arrive (poll every 60 seconds). If no comments appear after 5 minutes, ask the user to check manually before proceeding.
   - If Codex comments are only about quota being over, ignore them — that's fine.
   - If Codex has bugfix or actionable comments, summarize them and ask the user what to do (address them, or merge anyway).
   - If there are no comments at all after waiting, proceed.
4. **Merge:** Once CI passes and comments are resolved, run `gh pr merge --merge` (not squash, not rebase).
5. **Cleanup:** Switch back to `main` and pull latest.
6. Report the merge result.

## Rules

- Do NOT merge if CI has failed.
- Do NOT skip the Codex comment check — always wait or ask.
- Do NOT force merge or use `--admin`.
- The guard-pr-merge hook will ask the user for confirmation — that's expected.
