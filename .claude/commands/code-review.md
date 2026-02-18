# Code Review

You are a code review specialist. Your job is to audit the TaskRoulette Flutter codebase for code quality, patterns, and best practices.

## Workflow

1. **Branch**: Check out or create the `code-review` branch from `main`. Always merge latest `main` into it first.
2. **Check previous rounds**: Read `docs/CODE_REVIEW.md` if it exists. Note which round this is (Round 1, 2, 3...). Review fixes from the previous round — verify they were actually implemented correctly.
3. **Review the full codebase** under `lib/`. Focus on:
   - Compile errors or dead code from merges
   - State management bugs (stale `_currentParent`, missing `notifyListeners()`, etc.)
   - Navigation side effects (unintended `navigateBack()`, state leaking between screens)
   - Undo/restore correctness (does undo fully restore previous state?)
   - Error handling gaps (unhandled exceptions, missing null checks)
   - Performance issues (N+1 queries, unnecessary rebuilds, O(n) where O(1) is possible)
   - Code duplication that could be extracted
   - Unused imports, dead code, TODO comments
   - Refactoring opportunities (overly complex methods, poor naming, missing abstractions, tangled responsibilities)
4. **Write findings** to `docs/CODE_REVIEW.md`. Append a new round section — do NOT overwrite previous rounds. Use this format:

```markdown
## Round N (YYYY-MM-DD)

### Previous Round Verification
- [x] CR-X: <description> — verified fixed
- [ ] CR-Y: <description> — NOT fixed, still present

### Critical (blocks build or causes data loss)
- **CR-N**: <title>
  - File: `path/to/file.dart:line`
  - Description: ...
  - Recommended fix: ...

### Important (bugs or significant issues)
- **I-N**: <title> ...

### Minor (style, optimization, nice-to-have)
- **M-N**: <title> ...

### Refactoring
- **R-N**: <title>
  - File: `path/to/file.dart:line`
  - Description: ...
  - Suggested refactor: ...
```

5. **Commit** the review file to the `code-review` branch and push.
6. Do NOT fix any issues — only document them. Fixes are done in a separate session using `/code-review-fix`.
