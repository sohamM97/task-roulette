# Performance Optimizations

## Database Indices (v6)

Added indices on `task_relationships(parent_id)` and `task_relationships(child_id)`. Without these, every `getChildren()`, `getParents()`, `getRootTasks()`, and `hasPath()` query performed full table scans on `task_relationships`. With indices, SQLite uses index lookups instead — O(log n) vs O(n).

These are created in both `onCreate` (fresh installs) and `onUpgrade` (existing users upgrading to DB version 6).

## Transaction Batching

`restoreTask()` and `deleteTaskWithRelationships()` now wrap all their DB operations in a single `db.transaction()`. Benefits:

- **Fewer fsync calls**: SQLite commits once at the end instead of after each statement. On Android (flash storage), each fsync can take 10-50ms.
- **Atomicity**: If any insert/delete fails, the entire operation rolls back cleanly.
- **Reduced WAL overhead**: Single transaction = single WAL frame group instead of N separate ones.

## Debug Symbols

Release builds now use `--split-debug-info` and `--obfuscate`. The symbols zip is attached to each GitHub release. This allows symbolicating crash stacks and ANR traces from production.

### Symbolicating a crash trace

```bash
# Download debug-symbols.zip from the GitHub release
unzip debug-symbols.zip -d symbols/

# Symbolicate an Android stack trace
flutter symbolize -i stacktrace.txt -d symbols/
```

## Future Work

- **Isolate graph layout**: The Sugiyama algorithm from `graphview` runs on the main thread. For large graphs, this could cause jank. Moving it to an isolate requires serializable graph objects (the package's `Graph`/`Node` types aren't currently serializable).
- **Debounce `notifyListeners()`**: If DB queries are fast (which they should be with indices), this isn't needed. Revisit if profiling shows excessive rebuilds.
