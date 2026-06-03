---
name: test-suite
description: Run full test suite. Use when the user wants to run all tests and manual test checklists together.
---

# Full Test Suite

Run `/add-auto-tests` and `/manual-test` in parallel for the current changes.

## Workflow

Launch both skills simultaneously using the Agent tool, **always in the background** (`run_in_background: true`):
1. **Test generation agent** — runs `/add-auto-tests` with the `last` argument. **Important:** Tell the agent to look at the current branch's changes (both committed and uncommitted) compared to `main`, NOT other branches.
2. **Manual test agent** — runs `/manual-test`

Both agents MUST run in the background so the user can continue working.

## Presentation timing — ask the user

When the **manual test agent finishes first** (the common case, since the auto-test agent takes longer), **ask the user** whether they want to:
- **(a)** start the manual checklist now, or
- **(b)** wait until the auto-test agent finishes.

Default to whatever the user picks; if they don't express a preference, show the manual checklist immediately. The only reason to wait is that the auto-test agent might modify `lib/` files, which trigger hot-reload in `./dev.sh` and can disrupt manual testing mid-test (test files in `test/` are safe and don't reload). Surface this trade-off when asking so the user can decide.

Present the manual checklist **one section at a time** — never flatten all sections into a single list. Don't advance to the next section until the user reports results for the current one.

When presenting auto-test results, include the test category labels (Regression, Mechanism, Baseline, Edge case) from the agent's report so the user can see at a glance which tests guard the bug vs test the fix mechanism.
