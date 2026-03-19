---
name: code-review-fix
description: Code Review Fix. Use when fixing issues from a code review.
---

# Code Review Fix

You are fixing issues found during code review of the TaskRoulette Flutter codebase.

## Arguments

- Empty (default): fix the latest round's findings, then optionally tackle deferred items.
- `deferred`: skip directly to open/deferred items from previous rounds.

## Workflow

1. **Branch**: Make sure you're on the `code-review` branch. If not, check it out. Merge latest `main` if behind.
2. **Read findings**: Read `docs/CODE_REVIEW.md`.
   - If argument is `deferred`: skip to step 4 (deferred items only).
   - Otherwise: find the latest round's findings and proceed normally.
3. **Prioritize**: Fix in order — Critical first, then Important, then Minor. Skip items explicitly marked as "won't fix" or "deferred".
4. **Deferred items**: After fixing the latest round's findings (or immediately if `deferred` argument), find the "Items Still Open From Previous Rounds" section (or scan all rounds for unfixed items). For each open item:
   - First check if it was already fixed by other work (mark `[ALREADY FIXED]` if so).
   - Categorize remaining items by effort (quick/medium/large).
   - Present the list to the user and ask which ones to fix. **Do not skip items just because they are minor** — fix everything the user agrees to.
5. **Fix each issue**:
   - Read the relevant file(s) before making changes
   - Apply the fix
   - If the fix changes user-facing behavior, note it for the commit message
   - If the recommended fix doesn't make sense after reading the code, use your judgment
6. **Add test cases**: For each bug fix, add a regression test if one doesn't already exist. Run `flutter test` after each group of fixes.
7. **Build check**: Run `flutter build linux` to verify compilation.
8. **Update docs** in `docs/CODE_REVIEW.md`:
   - **For latest-round fixes**: mark each item with `[FIXED in Round N fix]`.
   - **For deferred fixes**: add a "Deferred Fix Round (YYYY-MM-DD)" section with tables summarizing what was fixed, what was already fixed, and what remains open. Example format:
     ```markdown
     ## Deferred Fix Round (YYYY-MM-DD)

     ### Fixed in This Round
     | ID | Title | Original Round |
     |----|-------|---------------|

     ### Already Fixed (by prior work)
     | ID | Title | Fixed By |
     |----|-------|----------|

     ### Remaining Open
     | ID | Title | Reason |
     |----|-------|--------|
     ```
   - If an item was already fixed before you touched it, mark it `[ALREADY FIXED]` at its original location too.
   - If you deviated from the recommended fix, add a brief note explaining what you did instead.
   - Update the "Items Still Open From Previous Rounds" section to reflect current state.
9. **Commit** all fixes to the `code-review` branch with a descriptive message summarizing what was fixed.
10. **Push** and remind the user to:
    - Run `/code-review verify` in a fresh session to confirm the fixes
    - Create a PR to merge `code-review` into `main`
