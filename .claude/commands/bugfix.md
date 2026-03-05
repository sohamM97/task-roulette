# Start a Bugfix

Create a bugfix branch from an up-to-date `main`.

## Arguments

The user may provide a short bugfix name (e.g. `stale-parent-data`). If not provided, ask them for a brief name.

## Workflow

1. Check that you're on the `main` branch. If not, ask the user if they want to switch to `main` first (there may be uncommitted work).
2. Run `git status` to check for uncommitted changes. If there are any, **stop** and tell the user to commit first (or offer to run `/commit`).
3. Pull latest `main` with `git pull`.
4. Create and switch to a new branch: `bugfix/<name>` (e.g. `bugfix/stale-parent-data`). Use kebab-case for the name.
5. Confirm the branch was created successfully. Then ask the user what they'd like to do — describe the bug, enter plan mode, or just start working.

## Rules

- Branch names must use `bugfix/` prefix with kebab-case (e.g. `bugfix/stale-parent-data`, not `bugfix/staleParentData`).
- Always branch from an up-to-date `main`.
- Do NOT automatically enter plan mode or start writing code. Wait for the user to describe what they want.
