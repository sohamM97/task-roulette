---
name: manual-test
description: Manual Test Checklist. Use when generating manual test instructions for the user.
---

# Manual Test Checklist

Generate a checklist of manual tests the user should run for recent changes.

## Arguments

- Optional: description of what changed (e.g. "normalization in Today's 5"). If omitted, infer from recent git diff or conversation context.

## Workflow

1. Identify what changed:
   - If the user described it, use that.
   - Otherwise, run `git diff main...HEAD --stat` and `git log main..HEAD --oneline` to understand the scope.
   - Read the modified files to understand the actual behavior changes.

2. Categorize the changes:
   - **Algorithm/logic changes** — things that affect behavior but not UI
   - **UI changes** — new widgets, layout changes, label changes
   - **Data/DB changes** — schema migrations, new queries
   - **Edge cases** — boundary conditions, empty states, error paths

3. **Before writing any test**, read `docs/UI_VIEWS.md` (in the project root) for canonical view names, then read the widget code for every screen/dialog touched by the changes. Note the exact button labels, icon names, menu item text, and how each interaction is triggered (tap, long press, swipe, overflow menu, etc.). Use view names from `docs/UI_VIEWS.md` consistently. Do NOT proceed to step 4 until you have read every relevant widget file.

4. Generate a numbered checklist of manual tests. Every UI element referenced MUST come from step 3's reading — never from memory or assumption. Format rules:
   - **Each entry is a concrete test case**, not a step. A test case has a clear action and expected outcome. Setup steps (creating tasks, navigating) go in a separate "Setup" section before the test cases, not as numbered test items. A test case that ends with "dialog appears" or "screen shows X" without verifying the final outcome is incomplete — it's a step, not a test. **Always use numbered lists** (1, 2, 3...), never bullet points or checkboxes.
   - **One line per test.** Full navigation path + action + expected result, joined by `→`. No multi-line explanations. Include how to get to the screen if it requires navigation (e.g. "On All Tasks tab, tap 'My task' to open leaf detail → tap 'Done today' → expect X").
   - **No tables.** Tables add visual bulk. Use a flat numbered list.
   - **Group by what changed**, not by screen. The user cares about "does the new behavior work?" not "let me exhaustively test every screen."
   - **Mark the key behavior changes** with ⚡ so the user can spot what's new vs regression checks.
   - Keep it scannable — if the user's eyes glaze over, it's too long.
   - **Each section must be self-contained.** Tests within a section can build on each other, but a new section/subheading must never assume state from a previous section. Include the exact steps to reach the required state.
   - **Every test case must name the screen/tab** where the action starts (e.g. "On Today's 5 tab, tap..." not just "Tap..."). Never assume the user knows which screen you mean from context.
   - **One test = one flow.** Each test case should verify a single behavior. Don't combine multiple if-else outcomes into one test (e.g. "should show X if Y, otherwise Z"). Split into separate tests with clear preconditions.
   - **Account for state consumed by prior tests.** If test 1 uses a task with a deadline and removes it, test 2 can't reuse that same task for a "keep deadline" test. Either specify separate tasks in the setup, or tell the user to undo/re-add state between tests.
   - **Specify the variant under test.** When a feature has distinct subtypes or modes (e.g. "due by" vs "scheduled on" deadlines, pinned vs unpinned tasks), each test case must state which variant it uses. Don't just say "a task with a deadline" — say "a task with a 'Due by' deadline".
   - **State the expected starting state** before the first test. Tell the user whether their existing app data is fine, or if they need a clean slate. Example: "Your existing tasks/pins won't interfere — these tests create new tasks." or "Clear Today's 5 first (New set → Replace) to start fresh."

5. Prioritize tests by risk:
   - Start with **happy path** tests that verify the core change works
   - Then **regression** tests for existing functionality that could break
   - Then **edge cases** (empty lists, single items, boundary values)

6. Keep the list practical — aim for 5-10 tests, not an exhaustive matrix. Focus on things automated tests can't easily cover (visual correctness, interaction feel, real data scenarios).

## Output Format

```
## Manual Test: [change name]

### Setup
Create [whatever state is needed for the tests below].

### [What changed]
1. ⚡ Do A → expect B (was C before fix)
2. Do X → expect Y

### Regression
3. Do X → still works as before
```

## Rules

- BLOCKING: You must read every relevant widget file in step 3 before generating any tests. If a test step mentions a UI element you haven't read the code for, delete the test and read the code first.
- **Keep `docs/UI_VIEWS.md` in sync.** If you discover UI behavior that is not documented in `docs/UI_VIEWS.md`, or that has changed from what is documented, update `docs/UI_VIEWS.md` as part of generating the test checklist. This ensures the reference stays accurate for future test runs.
- Never write instructions that contradict or omit app behavior. Use precise language that reflects how the app actually works. If the app does something automatically (e.g. deadline inheritance from parent to child), mention it explicitly so the user isn't confused when it happens. Don't say "no deadline" when the task inherits one — say "it will automatically inherit the parent's deadline".
- Only reference UI elements that actually exist on the screen. If the widget code shows an icon, don't say "shows the deadline" — say "shows the deadline icon". If information isn't visually displayed, don't ask the user to verify it.
- Don't suggest tests that duplicate what automated tests already cover — check the test files first.
- If a change is purely algorithmic with no UI impact, say so and focus tests on observable outcomes.
- Mention which platform to test on (Linux via `./dev.sh` unless the change is mobile-specific).
- **Present tests in batches by section.** Don't dump all test cases at once — show one section at a time (e.g. "Today's 5" tests first, then "All Tasks" after the user reports results). This prevents the list from feeling overwhelming and lets the user focus. **This applies to the caller too** — when presenting the agent's results, you MUST show only the first section and hold back the rest until the user reports results. Never flatten all sections into one list or present them all at once, even as a "summary". **Do NOT move to the next section until the user has reported results for ALL test cases in the current section.** If the user reports on only some tests (e.g. "1. works" but there are 10 tests), re-display the remaining tests from that section — do NOT advance to the next section.
- **Snackbar undo tests are time-sensitive.** The undo snackbar only lasts 5 seconds. Rules for undo tests:
  - An undo test must be a **separate, self-contained test case** — never an addendum tagged onto a non-undo test ("now tap Undo").
  - The undo tap must be the **very first action** after the trigger — no intermediate verification steps between the action and the undo. Verify the result of the undo AFTER tapping it, not before.
  - If the undo test requires the same setup as a non-undo test, tell the user to **re-do the setup** (or use a separate task) rather than chaining it after the non-undo test's verification steps.
  - Warn the user about the 5s window, and suggest a manual fallback path (e.g. unarchive + re-add state) if they miss it.
- The user reports results like "1. works / 2. works". If their list is incomplete (doesn't cover all test cases), don't assume they're skipping the rest. Ask (via AskUserQuestion, with "continue" as the default) whether they want to carry on or skip. If they want to carry on, re-display the remaining test cases so they don't have to scroll up.
