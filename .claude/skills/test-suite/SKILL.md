---
name: test-suite
description: Run full test suite. Use when the user wants to run all tests and manual test checklists together.
---

# Full Test Suite

Run `/add-auto-tests` and `/manual-test` in parallel for the current changes.

## Workflow

Launch both skills simultaneously using the Agent tool:
1. **Test generation agent** — runs `/add-auto-tests` with the `last` argument. **Important:** Tell the agent to look at the current branch's changes (both committed and uncommitted) compared to `main`, NOT other branches.
2. **Manual test agent** — runs `/manual-test`

Wait for both to complete, then present the combined results.
