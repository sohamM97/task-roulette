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

Both agents MUST run in the background so the user can continue working. Present combined results as each agent completes.

When presenting auto-test results, include the test category labels (Regression, Mechanism, Baseline, Edge case) from the agent's report so the user can see at a glance which tests guard the bug vs test the fix mechanism.
