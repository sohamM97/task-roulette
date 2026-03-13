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

3. Generate a numbered checklist of manual tests. For each test:
   - Describe the **setup** (what state to create — e.g. "create a root with 15+ leaf tasks")
   - Describe the **action** (what to do — e.g. "generate Today's 5 three times")
   - Describe the **expected result** (what to verify — e.g. "small root tasks appear at least once across 3 generations")

4. **IMPORTANT**: Before writing any test that references UI elements (button labels, icons, menu items, gestures), read the actual widget code to verify the element exists and how to interact with it. Never guess at UI details.

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

- Always verify UI elements by reading widget code before mentioning them in test steps.
- Don't suggest tests that duplicate what automated tests already cover — check the test files first.
- If a change is purely algorithmic with no UI impact, say so and focus tests on observable outcomes.
- Mention which platform to test on (Linux via `./dev.sh` unless the change is mobile-specific).
