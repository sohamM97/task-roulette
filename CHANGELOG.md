# Changelog

## v1.0.0 — First stable release

TaskRoulette is a DAG-based task manager designed for minimal cognitive load. Break big goals into smaller tasks, organize them in a flexible hierarchy (tasks can live under multiple parents), and let the app pick what to work on next.

### Core Features

- **DAG task hierarchy** — tasks can have multiple parents, forming a directed acyclic graph instead of a rigid tree. Cycle prevention built in.
- **Today's 5** — each day, the app picks 5 actionable leaf tasks using weighted random selection. Swap individual tasks, refresh the whole set, or mark them done as you go.
- **Weighted random selection** — task picking factors in priority, difficulty, started state, staleness (days since last worked on), and recency.
- **"Done today" vs "Done for good!"** — partial work counts. "Done today" resets the staleness clock so the task comes back later. "Done for good!" archives it permanently.
- **In-progress tracking** — mark tasks as "in progress" to boost their weight in random selection and see them at a glance.
- **Global search** — find any task from anywhere in the hierarchy and navigate directly to it.

### Task Management

- **Create, rename, delete** — with full undo support on delete.
- **Mid-hierarchy delete** — choose to reparent children or delete the entire subtree.
- **Move tasks** — relocate a task from one parent to another.
- **"Also show under..."** — add a task under multiple parents without duplicating it.
- **Brain dump mode** — long-press the add button to rapidly enter multiple tasks at once.
- **Priority** (Normal / High) and **Difficulty** (Easy / Medium / Hard) fields on leaf tasks.
- **URL field** — attach a link to any task, opens in browser.
- **Task dependencies** — soft "do this first" nudges between tasks.
- **Skip task** — dismiss a task without completing it.

### Views

- **All Tasks tab** — browse the full hierarchy with breadcrumb navigation and colored task cards.
- **Today's 5 tab** — daily focus view with progress bar and completion tracking.
- **Swipe between tabs** for quick switching.
- **DAG graph visualization** — see the full task graph with draggable nodes, zoom controls, and tap-to-navigate.
- **Archive screen** — view completed/skipped tasks, permanently delete, or restore with undo.

### Data & Privacy

- **Fully offline** — all data stored locally in SQLite. No accounts, no cloud, no tracking.
- **Export/import backup** — save your entire database to a file and restore it anytime. Share via Android share sheet or save to Downloads.
- **Input validation and backup file verification** — protects against corrupt or malicious imports.

### Platform Support

- **Android** (APK via GitHub Releases)

### Design

- **Dark and light themes** with persistent preference.
- **Material 3** theming throughout.
- **ADHD-friendly design philosophy** — minimal choices, sensible defaults, reduce friction not add it.
- **Custom app icon** — dark roulette wheel with checkmark.

### Quality

- **295 automated tests** — covering database operations, provider logic, models, widgets, and utilities.
- **2 rounds of code review** + **2 rounds of security review** — with all actionable findings fixed.
- **Performance optimized** — batch DB operations, cached lookups, indexed queries, consolidated state refreshes.
