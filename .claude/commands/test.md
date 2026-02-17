# Add Test Cases

Write and run test cases for the TaskRoulette Flutter app.

## Arguments

The user may specify one of two modes:
- **`last`** (or `feature`, `bug`, or a description) — add tests for the most recent feature or bug fix
- **`coverage`** (or `full`, `all`) — find and fill coverage gaps across the entire codebase

If no argument is provided, ask the user which mode they want.

## Mode 1: Last Feature/Bug

1. Run `git log --oneline -10` to identify the most recent feature or bug fix commits.
2. Read the changed files (`git diff main~N..main --name-only` or similar) to understand what was added/changed.
3. Read the existing test files to understand test patterns and conventions used in this project.
4. Write tests for the new/changed code:
   - Unit tests for new model fields, DB methods, or service logic
   - Provider tests for new state management behavior
   - Widget tests for new UI components (if testable without async issues — see Caveats)
5. Run `flutter test` to verify all tests pass.
6. Report what was added and the new test count.

## Mode 2: Coverage Gaps

1. Run `flutter test --coverage` to generate `coverage/lcov.info`.
2. Parse `coverage/lcov.info` directly to compute per-file line coverage. For each `SF:` section, count `DA:` lines where hits > 0 vs total `DA:` lines. Report files below 50% coverage. (Do NOT rely on `genhtml` or `lcov` — they may not be installed.)
3. Focus on files under `lib/` that are below 50% coverage.
4. Read those files and the existing tests to understand what's missing.
5. Write tests to improve coverage, prioritizing:
   - `lib/data/database_helper.dart` — DB operations
   - `lib/providers/task_provider.dart` — state management
   - `lib/models/task.dart` — model logic
   - `lib/services/` — sync and auth service logic (mock HTTP where needed)
6. Run `flutter test --coverage` again and compare before/after.
7. Report the coverage delta and remaining gaps.

## Test Conventions

- Test files mirror the `lib/` structure under `test/` (e.g. `lib/data/foo.dart` → `test/data/foo_test.dart`).
- DB tests use `sqflite_common_ffi` with in-memory databases.
- Widget tests use `WidgetTester` with `MaterialApp` wrapper.
- Provider tests instantiate the provider directly with a test DB.
- Group related tests with `group()`.
- Use descriptive test names that explain the expected behavior.

## Caveats

- **Async screens** (Today's 5, etc.): `pumpAndSettle` hangs on `CircularProgressIndicator` during loading state. Avoid widget tests for these screens unless you have a working async test harness.
- **Services with HTTP calls** (auth_service, firestore_service, sync_service): Mock the `http` package or use dependency injection to test logic without real network calls.
- Don't add tests that are trivially obvious (e.g. testing that a constructor sets fields). Focus on behavior and edge cases.

## Rules

- Always run `flutter test` after writing tests to verify they pass.
- Do NOT commit — just write the tests and report. The user will decide when to commit.
- If a test reveals an actual bug, flag it to the user immediately.
