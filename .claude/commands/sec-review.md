# Security Review

You are a security review specialist. Your job is to audit the TaskRoulette Flutter codebase for security vulnerabilities.

## Workflow

1. **Branch**: Check out or create the `sec-review` branch from `main`. Always merge latest `main` into it first.
2. **Check previous rounds**: Read `docs/SECURITY_REVIEW.md` if it exists. Note which round this is (Round 1, 2, 3...). Review fixes from the previous round — verify they were actually implemented correctly.
3. **Review the full codebase** under `lib/`, `android/`, and `pubspec.yaml`. Focus on:
   - **SQL injection**: All queries in `database_helper.dart` — parameterized? User input concatenated?
   - **Input validation**: Task names, URLs, search queries — length limits, scheme validation
   - **File handling**: Backup import/export — path traversal, size limits, format validation
   - **URL handling**: `url_launcher` calls — scheme allowlist, malicious URLs
   - **Android config**: Manifest permissions, exported components, backup settings, cleartext traffic
   - **Dependencies**: Check `pubspec.lock` versions against known CVEs
   - **Data at rest**: SQLite encryption, SharedPreferences tampering
   - **OWASP Mobile Top 10** assessment
4. **Write findings** to `docs/SECURITY_REVIEW.md`. Append a new round section — do NOT overwrite previous rounds. Use this format:

```markdown
## Round N (YYYY-MM-DD)

### Previous Round Verification
- [x] HIGH-1: <description> — verified fixed
- [ ] MED-2: <description> — NOT fixed, still present

### Findings

#### HIGH-N: <title>
- **Severity:** High
- **File:** `path/to/file.dart:line`
- **Description:** ...
- **Recommended Fix:** ...

#### MED-N: <title>
...

#### LOW-N: <title>
...

#### INFO-N: <title>
...

### Positive Security Findings
1. ...

### OWASP Mobile Top 10 Assessment
| Category | Status | Notes |
|----------|--------|-------|
| M1: ... | Pass/Action needed | ... |
```

5. **Commit** the review file to the `sec-review` branch and push.
6. Do NOT fix any issues — only document them. Fixes are done in a separate session using `/sec-review-fix`.
