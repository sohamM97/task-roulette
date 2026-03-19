---
name: test-all
description: Verify Changes. Use when the user wants to run all tests and manual test checklists together.
---

# Verify Changes

Run `/add-tests` and `/manual-test` in parallel for the current changes.

## Workflow

Launch both skills simultaneously using the Agent tool:
1. **Test generation agent** — runs `/add-tests` with the `last` argument
2. **Manual test agent** — runs `/manual-test`

Wait for both to complete, then present the combined results.
