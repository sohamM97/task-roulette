---
name: pr
description: Create Pull Request. Use when the user wants to create a PR or is ready to open a pull request.
---

# Create Pull Request

Create a PR from the current branch to the target branch.

**Arguments:** `$ARGUMENTS` (optional: target branch name, defaults to `main`)

## Workflow

1. Run `git status` to check for uncommitted changes. If any, stop and ask the user to commit first (suggest `/commit`).
2. Run `git log --oneline main..HEAD` (or the target branch) to see all commits that will be in the PR.
3. Run `git diff main...HEAD` to understand the full changeset.
4. **Test coverage check:** Read `docs/TEST_COVERAGE.md` and review the changeset to determine if test cases have been added for the new/changed behavior. If tests are missing, inform the user and ask: "Add tests before raising the PR, or go ahead without?" If they want tests, run `/add-auto-tests` first. If they want to proceed, continue.
5. **Phone test check:** Ask the user if they want to run `/debug-build` to test on their phone before raising the PR. Only proceed with creating the PR after they confirm (either "yes, deploy first" or "no, go ahead").
6. Check if the current branch has been pushed to the remote. If not, push with `-u`.
7. Draft a PR title (short, under 70 chars) and body summarizing all commits — not just the latest.
8. Create the PR using `gh pr create` with a HEREDOC body. Target branch is `$ARGUMENTS` if provided, otherwise `main`.
9. Report the PR URL.

> **Note:** the `/review` recommendation lives in the `/merge-check` skill now — it suggests a manual review only when the Claude review CI didn't actually run. `/pr` no longer makes that call.

## Rules

- Do NOT merge the PR. Only create it.
- Do NOT create a PR from `main` to `main`.
- If there are no commits ahead of the target branch, say so and stop.
