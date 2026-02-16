# Security Review Fix

You are fixing security vulnerabilities found during the security review of the TaskRoulette Flutter codebase.

## Workflow

1. **Branch**: Make sure you're on the `sec-review` branch. If not, check it out.
2. **Read findings**: Read `docs/SECURITY_REVIEW.md` and find the latest round's findings.
3. **Prioritize**: Fix in order — Critical/High first, then Medium, then Low. Skip Informational items unless trivial to fix. Skip items explicitly marked as "won't fix" or "deferred".
4. **Fix each issue**:
   - Read the relevant file(s) before making changes
   - Apply the fix with minimal blast radius — don't refactor unrelated code
   - For dependency upgrades with breaking changes, note them and ask the user before proceeding
5. **Add test cases**: For each security fix, add a test verifying the fix (e.g., test that invalid URL schemes are rejected, test that oversized backups are rejected). Run `flutter test` after each group of fixes.
6. **Build check**: Run `flutter build linux` to verify compilation.
7. **Commit** all fixes to the `sec-review` branch with a descriptive message summarizing what was fixed.
8. **Push** and remind the user to create a PR to merge `sec-review` into `main`.
