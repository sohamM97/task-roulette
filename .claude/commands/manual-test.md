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

4. Generate a numbered checklist of manual tests. Keep each test **short** — one line for what to do, one line for what to expect. No verbose setup paragraphs. The user should be able to scan the list quickly without getting bored. Every UI element referenced in a test step MUST come from step 3's reading — never from memory or assumption.

5. Prioritize tests by risk:
   - Start with **happy path** tests that verify the core change works
   - Then **regression** tests for existing functionality that could break
   - Then **edge cases** (empty lists, single items, boundary values)

6. Keep the list practical — aim for 5-10 tests, not an exhaustive matrix. Focus on things automated tests can't easily cover (visual correctness, interaction feel, real data scenarios).

## Output Format

```
## Manual Test Checklist: [feature/change name]

### Core Behavior
1. ...
2. ...

### Regression
3. ...
4. ...

### Edge Cases
5. ...
```

## Rules

- BLOCKING: You must read every relevant widget file in step 3 before generating any tests. If a test step mentions a UI element you haven't read the code for, delete the test and read the code first.
- Don't suggest tests that duplicate what automated tests already cover — check the test files first.
- If a change is purely algorithmic with no UI impact, say so and focus tests on observable outcomes.
- Mention which platform to test on (Linux via `./dev.sh` unless the change is mobile-specific).
