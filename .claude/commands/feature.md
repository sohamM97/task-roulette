# Start a New Feature

Create a feature branch from an up-to-date `main`.

## Arguments

The user may provide a short feature name (e.g. `pin-for-today`). If not provided, ask them for a brief name.

## Workflow

1. Check that you're on the `main` branch. If not, ask the user if they want to switch to `main` first (there may be uncommitted work).
2. Run `git status` to check for uncommitted changes. If there are any, **stop** and tell the user to commit first (or offer to run `/commit`).
3. Pull latest `main` with `git pull`.
4. Create and switch to a new branch: `feature/<name>` (e.g. `feature/pin-for-today`). Use kebab-case for the name.
5. Confirm the branch was created successfully. Then ask the user what they'd like to do — describe the feature, enter plan mode, or just start working.

## Rules

- Branch names must use `feature/` prefix with kebab-case (e.g. `feature/pin-for-today`, not `feature/pinForToday`).
- Always branch from an up-to-date `main`.
- Do NOT automatically enter plan mode or start writing code. Wait for the user to describe what they want.
