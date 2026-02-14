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

## DAG View: Cached Layout

The `GraphView` widget from the `graphview` package recomputes all 5 Sugiyama layout phases on every `performLayout()` call with zero caching — causing ANR on Android for larger graphs. We replaced it with a custom rendering approach:

- `SugiyamaAlgorithm` runs **once** in `_computeLayout()` (called from `initState()`, not `build()`)
- Node positions and edge paths are cached in state fields (`_nodePositions`, `_edgePaths`, `_graphSize`)
- Rendering uses `Stack` + `Positioned` (nodes) + `CustomPaint` (edges) — pure widget build with zero layout recomputation
- 1-finger panning enabled (`panEnabled: true` on `InteractiveViewer`)
- Auto-fit-to-screen on load via `addPostFrameCallback`

## Brain Dump Batch Insert

Brain dump (adding multiple tasks at once) previously called `addTask()` N times sequentially — each triggering a DB insert, relationship insert, full task list reload, auxiliary data queries, and `notifyListeners()`. Now uses `insertTasksBatch()` which wraps all inserts in a single transaction, followed by one refresh.

## Provider Refresh Consolidation

All navigation methods (`loadRootTasks`, `navigateInto`, `navigateBack`, `navigateToLevel`, `navigateToTask`) previously duplicated the "load task list + compute auxiliary data + notify listeners" pattern inline. Now they set parent/stack state and delegate to a single `_refreshCurrentList()` pipeline.

The two auxiliary queries (started-descendant IDs and blocked-task info) are independent and run concurrently via `Future.wait` in `_loadAuxiliaryData()`.

## UI Rebuild Reduction

- **TaskPickerDialog**: The `_filtered` getter (which sorts/filters all candidates) was being recomputed multiple times per `build()` call. Now computed once into a local variable.
- **Leaf detail FutureBuilder**: `getDependencies()` was called on every `Consumer` rebuild, creating a new `Future` each time. Now cached in state and only recreated when the task ID changes or a dependency mutation occurs.
- **Task list candidate prep**: Five methods (`_searchTask`, `_linkExistingTask`, `_addParentToTask`, `_moveTask`, `_addDependencyToTask`) each fetched `getAllTasks()` and `getParentNamesMap()` sequentially. Now use a shared `_fetchCandidateData()` helper that runs both concurrently.

## DB Mapping Centralization

Repeated `maps.map((m) => Task.fromMap(m)).toList()` calls across 7 query methods and inline parent-name grouping loops in 2 methods are replaced by shared static helpers (`_tasksFromMaps`, `_parentNamesFromRows`).

## Archive Label Caching

`_archivedLabel()` was recomputed per row per rebuild, each calling `DateTime.now()` and doing date arithmetic. Now labels are precomputed once in `_loadData()` using a single `now`/`today` snapshot and stored in a `Map<int, String>`.

## Future Work

- **Isolate graph layout**: The Sugiyama algorithm runs on the main thread. For <200 nodes this is <50ms, but for larger graphs it could cause jank. Moving it to an isolate requires serializable graph objects (the package's `Graph`/`Node` types aren't currently serializable).
- **Debounce `notifyListeners()`**: If DB queries are fast (which they should be with indices), this isn't needed. Revisit if profiling shows excessive rebuilds.
