---
name: add-auto-tests
description: Generate automated tests. Use when the user asks to add tests, write tests, or after completing a feature.
---

# Generate Tests

Generate test cases for the TaskRoulette Flutter app.

## Pre-flight: Consult Test Memory

**Before reading any test files**, read `docs/TEST_COVERAGE.md`. It tracks what's already covered, what's not, and known caveats. Use it to skip redundant exploration and jump straight to writing tests. After writing tests, update the file to reflect new coverage.

## Arguments

The user may specify one of two modes:
- **`last`** (or `feature`, `bug`, or a description) — add tests for the most recent feature or bug fix
- **`coverage`** (or `full`, `all`) — find and fill coverage gaps across the entire codebase

If no argument is provided, ask the user which mode they want.

## Mode 1: Last Feature/Bug

1. Read `docs/TEST_COVERAGE.md` to understand existing coverage landscape.
2. Check the **current branch** with `git branch --show-current` and compare against `main`:
   - `git diff main...HEAD --name-only` for committed changes on this branch
   - `git diff --name-only` for uncommitted changes
   - If both are empty, fall back to `git log --oneline -10` on the current branch
3. Read the changed files to understand what was added/changed. **Always use the current branch** — do not look at other branches.
4. Only read existing test files if `TEST_COVERAGE.md` doesn't have enough detail for the area being tested.
5. Write tests for the new/changed code:
   - Unit tests for new model fields, DB methods, or service logic
   - Provider tests for new state management behavior
   - Widget tests for new UI components (if testable without async issues — see Caveats)
6. Run `flutter test` to verify all tests pass.
7. Update `docs/TEST_COVERAGE.md` with the new tests added.
8. Report what was added and the new test count.

## Mode 2: Coverage Gaps

1. Read `docs/TEST_COVERAGE.md` to understand existing coverage and known gaps.
2. Run `flutter test --coverage` to generate `coverage/lcov.info`.
3. Parse `coverage/lcov.info` directly to compute per-file line coverage. For each `SF:` section, count `DA:` lines where hits > 0 vs total `DA:` lines. Report files below 50% coverage. (Do NOT rely on `genhtml` or `lcov` — they may not be installed.)
4. Cross-reference with `TEST_COVERAGE.md` — focus on gaps not already marked as "intentionally skipped".
5. Write tests to improve coverage, prioritizing:
   - `lib/data/database_helper.dart` — DB operations
   - `lib/providers/task_provider.dart` — state management
   - `lib/models/task.dart` — model logic
   - `lib/services/` — sync and auth service logic (mock HTTP where needed)
6. Run `flutter test --coverage` again and compare before/after.
7. Update `docs/TEST_COVERAGE.md` with new coverage and remaining gaps.
8. Report the coverage delta and remaining gaps.

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

- Always run `flutter analyze` and `flutter test` after writing tests to verify they pass with no warnings.
- Do NOT commit — just write the tests and report. The user will decide when to commit.
- If a test reveals an actual bug, flag it to the user immediately.
