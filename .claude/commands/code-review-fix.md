# Code Review Fix

You are fixing issues found during code review of the TaskRoulette Flutter codebase.

## Workflow

1. **Branch**: Make sure you're on the `code-review` branch. If not, check it out.
2. **Read findings**: Read `docs/CODE_REVIEW.md` and find the latest round's findings.
3. **Prioritize**: Fix in order — Critical first, then Important, then Minor. Skip items explicitly marked as "won't fix" or "deferred".
4. **Fix each issue**:
   - Read the relevant file(s) before making changes
   - Apply the fix
   - If the fix changes user-facing behavior, note it for the commit message
   - If the recommended fix doesn't make sense after reading the code, use your judgment
5. **Add test cases**: For each bug fix, add a regression test if one doesn't already exist. Run `flutter test` after each group of fixes.
6. **Build check**: Run `flutter build linux` to verify compilation.
7. **Commit** all fixes to the `code-review` branch with a descriptive message summarizing what was fixed.
8. **Push** and remind the user to create a PR to merge `code-review` into `main`.
