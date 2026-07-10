---
name: cleardb
description: Clear the local dev database. Use when the user wants to wipe/flush/reset the app's local DB (also /flushdb) for a clean slate.
disable-model-invocation: true
---

# Clear Local DB (`/cleardb`, a.k.a. `/flushdb`)

Wipes the Linux dev app's local SQLite database so the app starts from an empty
state. Destructive — but always takes a timestamped backup first, so it is
reversible.

**DB location:** `~/.local/share/com.taskroulette.task_roulette/task_roulette.db`
(the app recreates a fresh, empty schema at the current `_dbVersion` on next
launch — deleting the file is equivalent to clearing all tables.)

## Workflow

1. **Locate & inspect.** Set `DBDIR="$HOME/.local/share/com.taskroulette.task_roulette"`
   and `DB="$DBDIR/task_roulette.db"`. `ls -la "$DBDIR"`. If `task_roulette.db`
   doesn't exist, the DB is already empty/absent — say so and stop.
2. **Stop the running app** (a live app holds the DB open and would keep showing
   cached data / could rewrite on exit). Find it:
   `pgrep -af "task_roulette|dev.sh"`. Kill the matched PIDs
   (`kill <pids>`). This ends the `./dev.sh` hot-reload session too — that's
   expected; a full restart is needed for the empty DB to take effect anyway.
3. **Back up first (safety, always).** This is a dev machine — the local DB is
   often the only copy. Copy before deleting:
   `cp -v "$DB" "$DBDIR/task_roulette.db.preclear_$(date +%Y%m%d_%H%M%S)"`.
   Report the backup path so the user can restore with a plain `cp` back.
4. **Delete the DB files:** `rm -fv "$DB" "$DB-wal" "$DB-shm"` (the `-wal`/`-shm`
   may not exist — `-f` ignores that).
5. **Tell the user to relaunch** `./dev.sh` — the app recreates an empty DB with
   the latest schema on startup.

## Rules

- **Never skip the backup.** Always take the timestamped `.preclear_*` copy
  before deleting, even if the user is in a hurry.
- Only touch `task_roulette.db` (+ its `-wal`/`-shm`). Do **not** delete the
  existing `.bak` / `.backup_*` / `.preclear_*` files (those are prior backups)
  or `shared_preferences.json` (app settings, not task data).
- Don't run this while a release/manual test that depends on existing data is
  mid-flight without confirming — clearing is only for a deliberate clean slate.
- To restore: `cp "$DBDIR/task_roulette.db.preclear_<ts>" "$DBDIR/task_roulette.db"`
  (with the app stopped), then relaunch.
