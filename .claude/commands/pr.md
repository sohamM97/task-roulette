# Create Pull Request

Create a PR from the current branch to the target branch.

**Arguments:** `$ARGUMENTS` (optional: target branch name, defaults to `main`)

## Workflow

1. Run `git status` to check for uncommitted changes. If any, stop and ask the user to commit first (suggest `/commit`).
2. Run `git log --oneline main..HEAD` (or the target branch) to see all commits that will be in the PR.
3. Run `git diff main...HEAD` to understand the full changeset.
4. **Test coverage check:** Read `docs/TEST_COVERAGE.md` and review the changeset to determine if test cases have been added for the new/changed behavior. If tests are missing, inform the user and ask: "Add tests before raising the PR, or go ahead without?" If they want tests, run `/add-tests` first. If they want to proceed, continue.
5. Check if the current branch has been pushed to the remote. If not, push with `-u`.
6. Draft a PR title (short, under 70 chars) and body summarizing all commits — not just the latest.
7. Create the PR using `gh pr create` with a HEREDOC body. Target branch is `$ARGUMENTS` if provided, otherwise `main`.
8. Report the PR URL.
9. For large or feature PRs, suggest running `/review` in a **fresh session** before merging.

## Rules

- Do NOT merge the PR. Only create it.
- Do NOT create a PR from `main` to `main`.
- If there are no commits ahead of the target branch, say so and stop.
