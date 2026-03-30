---
name: commit
description: Commit and Push. Use when committing changes, pushing code, or when the user agrees to commit.
---

# Commit and Push

Commit all current uncommitted changes and push to the remote.

## Workflow

1. Run `git status` and `git diff` to see what's changed.
2. Run `git log --oneline -3` to match the repo's commit message style.
3. Stage all relevant changed files by name (do NOT use `git add -A` or `git add .`).
4. Write a concise commit message summarizing the changes — focus on "why" not "what".
5. Commit using a HEREDOC for the message.
6. Push to the current branch's remote.
7. Report the commit hash and branch.

## Rules

- Do NOT commit files that look like secrets (`.env`, credentials, keys).
- Do NOT amend previous commits — always create a new commit.
- Do NOT force push.
- If there are no changes to commit, say so and stop.
- If any changed files are under `lib/screens/` or `lib/widgets/` and modify UI (new/changed dialogs, buttons, toggles, interaction patterns), check whether `docs/UI_VIEWS.md` needs updating. Remind the user if it hasn't been updated.
