# Code Review Fix

You are fixing issues found during code review of the TaskRoulette Flutter codebase.

## Arguments

- Optional: `deferred` — skip to fixing open/deferred items from previous rounds instead of the latest round.

## Workflow

1. **Branch**: Make sure you're on the `code-review` branch. If not, check it out.
2. **Read findings**: Read `docs/CODE_REVIEW.md`.
   - If argument is `deferred`: skip to step 4 (deferred items only).
   - Otherwise: find the latest round's findings and proceed normally.
3. **Prioritize**: Fix in order — Critical first, then Important, then Minor. Skip items explicitly marked as "won't fix" or "deferred".
4. **Deferred items**: After fixing the latest round's findings (or immediately if `deferred` argument), check open/deferred items from earlier rounds. Categorize them by effort (quick/medium/large), present the list to the user, and ask which ones to fix.
5. **Fix each issue**:
   - Read the relevant file(s) before making changes
   - Apply the fix
   - If the fix changes user-facing behavior, note it for the commit message
   - If the recommended fix doesn't make sense after reading the code, use your judgment
6. **Add test cases**: For each bug fix, add a regression test if one doesn't already exist. Run `flutter test` after each group of fixes.
7. **Build check**: Run `flutter build linux` to verify compilation.
8. **Update docs**: In `docs/CODE_REVIEW.md`, mark each fixed item with `[FIXED in Round N fix]` next to its heading. If an item was already fixed before you touched it, mark it `[ALREADY FIXED]`. If you used your judgment and deviated from the recommended fix, add a brief note explaining what you did instead.
9. **Commit** all fixes to the `code-review` branch with a descriptive message summarizing what was fixed.
10. **Push** and remind the user to:
    - Run `/code-review verify` in a fresh session to confirm the fixes before merging
    - Create a PR to merge `code-review` into `main`
