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

3. **Before writing any test**, read the widget code for every screen/dialog touched by the changes. Note the exact button labels, icon names, menu item text, and how each interaction is triggered (tap, long press, swipe, overflow menu, etc.). Do NOT proceed to step 4 until you have read every relevant widget file.

4. Generate a numbered checklist of manual tests. Every UI element referenced MUST come from step 3's reading — never from memory or assumption. Format rules:
   - **Each entry is a concrete test case**, not a step. A test case has a clear action and expected outcome. Setup steps (creating tasks, navigating) go in a separate "Setup" section before the test cases, not as numbered test items.
   - **One line per test.** Action → expected result, joined by `→`. No multi-line explanations.
   - **No tables.** Tables add visual bulk. Use a flat numbered list.
   - **Group by what changed**, not by screen. The user cares about "does the new behavior work?" not "let me exhaustively test every screen."
   - **Mark the key behavior changes** with ⚡ so the user can spot what's new vs regression checks.
   - Keep it scannable — if the user's eyes glaze over, it's too long.
   - **Each section must be self-contained.** Tests within a section can build on each other, but a new section/subheading must never assume state from a previous section. Include the exact steps to reach the required state.
   - **Every test case must name the screen/tab** where the action starts (e.g. "On Today's 5 tab, tap..." not just "Tap..."). Never assume the user knows which screen you mean from context.
   - **One test = one flow.** Each test case should verify a single behavior. Don't combine multiple if-else outcomes into one test (e.g. "should show X if Y, otherwise Z"). Split into separate tests with clear preconditions.
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
- Never write instructions that contradict or omit app behavior. Use precise language that reflects how the app actually works. If the app does something automatically (e.g. deadline inheritance from parent to child), mention it explicitly so the user isn't confused when it happens. Don't say "no deadline" when the task inherits one — say "it will automatically inherit the parent's deadline".
- Only reference UI elements that actually exist on the screen. If the widget code shows an icon, don't say "shows the deadline" — say "shows the deadline icon". If information isn't visually displayed, don't ask the user to verify it.
- Don't suggest tests that duplicate what automated tests already cover — check the test files first.
- If a change is purely algorithmic with no UI impact, say so and focus tests on observable outcomes.
- Mention which platform to test on (Linux via `./dev.sh` unless the change is mobile-specific).
- The user reports results like "1. works / 2. works". If their list is incomplete (doesn't cover all test cases), don't assume they're skipping the rest. Ask (via AskUserQuestion, with "continue" as the default) whether they want to carry on or skip. If they want to carry on, re-display the remaining test cases so they don't have to scroll up.
