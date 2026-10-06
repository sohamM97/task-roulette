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

**Split a section further when its setup is multi-step.** Send the setup on its own, wait for the user to confirm it's done, then send the tests. A section that opens with "add these 5 tasks, then add a child, then set a deadline, then add a dependency" followed by 7 numbered tests is a wall — the user loses their place and ends up several steps behind where your next reply assumes they are.

**Never name a task or row the user hasn't created yet.** Referring to a later step's fixture while they're still on an earlier step reads as an instruction for right now, and nothing on screen matches it.

**Check each setup against the `/manual-test` rules before sending it — don't relay the agent's text as-is.** The agent's checklist can break its own rules, and you are the last check before the user. The rule most often broken is creating tasks with single adds instead of "Add multiple": tasks at the same level that share an Inbox state go in one batch, and two Inbox states mean two batches. Rewrite a setup that has two or more single adds of that kind before sending it.

When the user reports a partial result, asks a question, or gets stuck mid-section, answer only that and re-send the single step they're on. Don't advance.

When presenting auto-test results, include the test category labels (Regression, Mechanism, Baseline, Edge case) from the agent's report so the user can see at a glance which tests guard the bug vs test the fix mechanism.
