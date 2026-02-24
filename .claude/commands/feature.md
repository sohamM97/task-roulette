# Start a New Feature

Create a feature branch and enter plan mode for designing a big feature.

## Arguments

The user may provide a short feature name (e.g. `pin-for-today`). If not provided, ask them for a brief name.

## Workflow

1. Check that you're on the `main` branch. If not, ask the user if they want to switch to `main` first (there may be uncommitted work).
2. Run `git status` to check for uncommitted changes. If there are any, **stop** and tell the user to commit first (or offer to run `/commit`).
3. Pull latest `main` with `git pull`.
4. Create and switch to a new branch: `feature/<name>` (e.g. `feature/pin-for-today`). Use kebab-case for the name.
5. Enter plan mode to design the feature before writing any code.

## Rules

- Branch names must use `feature/` prefix with kebab-case (e.g. `feature/pin-for-today`, not `feature/pinForToday`).
- Always branch from an up-to-date `main`.
- Do NOT write any code before the plan is approved by the user.
- The plan should cover: what changes, which files, and verification steps.
