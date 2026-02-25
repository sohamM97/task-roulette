# TaskRoulette Security Review

**Date:** 2026-02-16
**Scope:** Full codebase review (SQL injection, data handling, file system, URL handling, input validation, Android config, dependencies, data at rest, SharedPreferences, OWASP Mobile Top 10)

---

## Executive Summary

The codebase has a **good security posture** for a local-only personal task manager. **No critical vulnerabilities** were found. All SQL queries are properly parameterized, no sensitive data (passwords, tokens, keys) is stored, and there are zero logging statements that could leak data in production.

The most actionable findings are:
1. **HIGH:** Outdated `file_picker` dependency with known XXE CVEs
2. **MEDIUM:** No URL scheme validation before launching URLs (2 locations)
3. **MEDIUM:** Insufficient backup import validation (no size limit, no trigger/view check, no schema version check)

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 1 |
| Medium | 5 |
| Low | 11 |
| Informational | 6 |

---

## Findings

### HIGH-1: Outdated `file_picker` with Critical XXE CVEs

- **Severity:** High
- **File:** `pubspec.yaml` / `pubspec.lock`
- **Locked version:** 8.3.7 | **Latest:** 10.3.10
- **CVEs:** CVE-2025-66516, CVE-2025-54988 (Critical XXE vulnerability in bundled Apache Tika library)

**Description:** The `file_picker` package is 2 major versions behind. Versions 10.3.9/10.3.10 explicitly patch critical XXE (XML External Entity) vulnerabilities. XXE can allow reading arbitrary files from the device and denial of service. The app uses `FilePicker.platform.pickFiles(type: FileType.any)` in `backup_service.dart:57` for database import with no file extension filter.

**Recommended Fix:**
```yaml
# pubspec.yaml
file_picker: ^10.3.10
```
Note: Major version bump may include breaking changes (`compressionQuality` default changed in 10.0.0, `allowCompression` deprecated). Test thoroughly after upgrading.

---

### MED-1: No URL Scheme Validation Before `launchUrl` (Leaf Detail)

- **Severity:** Medium
- **File:** `lib/widgets/leaf_task_detail.dart:47-58`
- **Code:**
  ```dart
  final uri = Uri.tryParse(task.url!);
  if (uri == null) { ... return; }
  final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  ```

**Description:** User-supplied URLs are parsed and launched without validating the URI scheme. Dangerous schemes like `file:///etc/passwd`, `intent:` (Android), `tel:`, `sms:` could cause unintended behavior -- opening local files, triggering phone calls, or launching arbitrary Android intents. While `LaunchMode.externalApplication` delegates to the OS which mitigates some attacks, it doesn't block all dangerous schemes.

**Recommended Fix:**
```dart
final uri = Uri.tryParse(task.url!);
if (uri == null || !['http', 'https'].contains(uri.scheme.toLowerCase())) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Only web links (http/https) are supported')),
  );
  return;
}
```

---

### MED-2: No URL Scheme Validation Before `launchUrl` (AppBar)

- **Severity:** Medium
- **File:** `lib/screens/task_list_screen.dart:728-731`
- **Code:**
  ```dart
  final uri = Uri.tryParse(provider.currentParent!.url!);
  if (uri != null) {
    launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  ```

**Description:** Same vulnerability as MED-1 but in a separate code path (the AppBar link icon button). Needs the same scheme allowlist fix.

**Recommended Fix:** Apply the same `http`/`https` scheme check as MED-1. Consider extracting a shared `launchSafeUrl()` utility to avoid duplication.

---

### MED-3: Minimal Schema Validation on Database Import

- **Severity:** Medium
- **File:** `lib/data/database_helper.dart:168-183`
- **Code:**
  ```dart
  Future<void> _validateBackup(String sourcePath) async {
    testDb = await openDatabase(sourcePath, readOnly: true);
    final tables = await testDb.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='tasks'",
    );
    if (tables.isEmpty) {
      throw const FormatException('Not a valid TaskRoulette backup');
    }
  }
  ```

**Description:** Validation only checks that a `tasks` table exists. It does NOT verify:
- Schema version (`PRAGMA user_version`) -- a DB from a future app version could crash on downgrade
- Expected tables (`task_relationships`, `task_dependencies`)
- Column schema of the `tasks` table
- Absence of malicious triggers or views (a crafted DB could include triggers that fire on INSERT/UPDATE and silently modify or delete data)

**Recommended Fix:** Add to `_validateBackup`:
```dart
// Check schema version
final versionResult = await testDb.rawQuery('PRAGMA user_version');
final version = versionResult.first.values.first as int;
if (version < 1 || version > 11) {
  throw const FormatException('Incompatible backup version');
}

// Check for unexpected triggers/views
final dangerous = await testDb.rawQuery(
  "SELECT name FROM sqlite_master WHERE type IN ('trigger', 'view')",
);
if (dangerous.isNotEmpty) {
  throw const FormatException('Backup contains unexpected database objects');
}

// Verify all expected tables exist
for (final table in ['tasks', 'task_relationships', 'task_dependencies']) {
  final result = await testDb.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table],
  );
  if (result.isEmpty) {
    throw FormatException('Missing table: $table');
  }
}
```

---

### MED-4: No File Size Limit on Database Import

- **Severity:** Medium
- **File:** `lib/data/database_helper.dart:196`
- **Code:**
  ```dart
  await File(sourcePath).copy(dbPath);
  ```

**Description:** No check on the size of the selected file before copying. A multi-gigabyte file would fill device storage, potentially crashing the app and other apps on the device.

**Recommended Fix:**
```dart
final fileSize = await File(sourcePath).length();
if (fileSize > 100 * 1024 * 1024) { // 100 MB
  throw const FormatException('Backup file is too large (max 100 MB)');
}
```

---

### MED-5: No R8/ProGuard Code Shrinking for Android Release

- **Severity:** Medium
- **File:** `android/app/build.gradle.kts:51-57`
- **Code:**
  ```kotlin
  buildTypes {
      release {
          signingConfig = if (keystorePropertiesFile.exists()) {
              signingConfigs.getByName("release")
          } else {
              signingConfigs.getByName("debug")
          }
      }
  }
  ```

**Description:** The release build type does not enable `isMinifyEnabled` (R8 code shrinking) or `isShrinkResources`. The Android/Kotlin layer ships unobfuscated, making reverse engineering easier. (Dart code is AOT-compiled and not affected by ProGuard, but plugin host code remains exposed.) This also increases APK size.

**Recommended Fix:**
```kotlin
release {
    isMinifyEnabled = true
    isShrinkResources = true
    proguardFiles(
        getDefaultProguardFile("proguard-android-optimize.txt"),
        "proguard-rules.pro"
    )
    // ... signing config
}
```
Create `android/app/proguard-rules.pro` with rules to keep Flutter engine classes. Test thoroughly after enabling.

---

### LOW-1: No URL Validation on Save

- **Severity:** Low
- **File:** `lib/widgets/leaf_task_detail.dart:73-133`
- **Description:** The URL edit dialog accepts any string and stores it directly in the database with no validation. This is the entry point that enables MED-1 and MED-2. Validating at save time (scheme check) provides defense-in-depth and also protects against malicious URLs in imported backups.
- **Recommended Fix:** Validate the URL has an `http`/`https` scheme before saving, or auto-prepend `https://` for bare domains.

---

### LOW-2: No Input Length Limits on Task Names

- **Severity:** Low
- **Files:** `lib/widgets/add_task_dialog.dart:45-54`, `lib/widgets/brain_dump_dialog.dart:67-77`, `lib/screens/task_list_screen.dart:202-207` (rename dialog)
- **Description:** No `maxLength` on task name `TextField` widgets. Extremely long strings (megabytes) could be pasted, causing performance issues in the grid view and database bloat.
- **Recommended Fix:** Add `maxLength: 500` (or similar reasonable limit) to all task name input fields.

---

### LOW-3: Malicious Triggers/Views in Imported Database

- **Severity:** Low
- **File:** `lib/data/database_helper.dart:196`
- **Description:** A crafted `.db` file could contain SQLite triggers that fire on subsequent INSERT/UPDATE operations, silently modifying or deleting data. While SQLite triggers cannot execute arbitrary system commands, they can manipulate data within the database. This is addressed by the trigger check in MED-3's recommended fix.

---

### LOW-4: No Pre-Import Backup of Existing Data

- **Severity:** Low
- **File:** `lib/data/database_helper.dart:188-197`
- **Description:** The existing database is overwritten during import without creating a backup first. If the imported file is corrupt or wrong, user data is permanently lost. The UI warns "cannot be undone" which is honest, but a safety backup would be better.
- **Recommended Fix:** Copy current `.db` to `.db.bak` before overwriting.

---

### LOW-5: `int.parse` Without Error Handling on SharedPreferences

- **Severity:** Low
- **File:** `lib/screens/todays_five_screen.dart:47,49`
- **Code:**
  ```dart
  final savedCompletedIds = completedIds.map(int.parse).toSet();
  final idSet = savedIds.map(int.parse).toSet();
  ```
- **Description:** If SharedPreferences data is corrupted (e.g., a non-numeric string), `int.parse` throws a `FormatException` and the screen fails to load. Requires root access or a compromised device to exploit on Android.
- **Recommended Fix:** Replace with `int.tryParse` and filter nulls:
  ```dart
  final idSet = savedIds.map(int.tryParse).whereType<int>().toSet();
  ```

---

### LOW-6: Unencrypted Database at Rest

- **Severity:** Low
- **File:** `lib/data/database_helper.dart:25-44`
- **Description:** The SQLite database is stored unencrypted. On Android it's in the app's sandboxed storage (inaccessible without root). On Linux it's at `~/.local/share/com.taskroulette.task_roulette/task_roulette.db` (protected by user permissions). The data model contains only task names, URLs, and timestamps -- no passwords, tokens, or PII. **Acceptable for this app's threat model.**
- **Recommended Fix:** No action needed now. If sensitive data fields are ever added, consider `sqflite_sqlcipher` for at-rest encryption.

---

### LOW-7: Backup Exported Unencrypted to World-Readable Location

- **Severity:** Low
- **File:** `lib/services/backup_service.dart:24-38`
- **Description:** The raw database is exported to `~/Downloads` (Linux) or `/storage/emulated/0/Download` (Android) without encryption. On Android, the Downloads folder is accessible to other apps with storage permission.
- **Recommended Fix:** Consider informing the user that backups are unencrypted. Optionally restrict file permissions on Linux (`chmod 600`).

---

### LOW-8: Missing `android:allowBackup="false"`

- **Severity:** Low
- **File:** `android/app/src/main/AndroidManifest.xml:2-5`
- **Description:** When `android:allowBackup` is not specified, it defaults to `true`. The app's SQLite database can be extracted via `adb backup` on Android 11 and below, or synced to Google Drive via Auto Backup.
- **Recommended Fix:** Add `android:allowBackup="false"` to the `<application>` tag if backup extraction is undesired.

---

### LOW-9: Release Signing Falls Back to Debug Key

- **Severity:** Low
- **File:** `android/app/build.gradle.kts:52-57`
- **Description:** If `key.properties` is missing, the release build silently falls back to the debug signing key. This could lead to an accidentally debug-signed release APK that causes signature mismatch and data loss if installed over a properly-signed version.
- **Recommended Fix:** Log a warning when `key.properties` is absent:
  ```kotlin
  logger.warn("WARNING: key.properties not found, using debug signing!")
  ```

---

### LOW-10: Unhandled `StateError` from `firstWhere`

- **Severity:** Low
- **File:** `lib/providers/task_provider.dart:98, 176, 187`
- **Description:** `firstWhere` without `orElse` throws `StateError` if the task is not in the current list (possible if the list was refreshed between user action and execution). Could crash the screen.
- **Recommended Fix:** Add `orElse` clauses or fetch from the database as a fallback.

---

### LOW-11: `share_plus` is 2 Major Versions Behind

- **Severity:** Low
- **File:** `pubspec.yaml` / `pubspec.lock`
- **Locked version:** 10.1.4 | **Latest:** 12.0.1
- **Description:** No known CVEs, but being 2 major versions behind means potentially missing bug fixes and platform compatibility improvements. Used only for sharing backup files on Android.
- **Recommended Fix:** Update when convenient.

---

### INFO-1: SQLite System Library CVEs

- **Severity:** Informational
- **Description:** Recent SQLite CVEs (CVE-2025-29087 integer overflow in `concat_ws()`, CVE-2025-6965 aggregate term overflow) affect the underlying SQLite library. On Linux, the system `libsqlite3` is used -- keep it updated. On Android, `sqflite_android` bundles its own version. The app's parameterized queries and simple SQL patterns make exploitation unlikely, but the backup import feature opens user-provided `.db` files which increases the attack surface.
- **Recommended Fix:** Keep system SQLite updated. Consider adding SQLite magic-byte validation to backup import.

---

### INFO-2: No Explicit `android:usesCleartextTraffic="false"`

- **Severity:** Informational
- **File:** `android/app/src/main/AndroidManifest.xml`
- **Description:** Not explicitly set, but `targetSdk >= 28` blocks cleartext traffic by default. Already secure. Setting it explicitly would be self-documenting.

---

### INFO-3: SDK Versions Delegated to Flutter Defaults

- **Severity:** Informational
- **File:** `android/app/build.gradle.kts:36-37`
- **Description:** `minSdk` and `targetSdk` are set to Flutter defaults (currently minSdk 21/Android 5.0, targetSdk 35/Android 15). minSdk 21 lacks some modern security features (network security config, scoped storage). Consider explicitly setting `minSdk = 24` (Android 7.0) for better security baseline, while still covering 99%+ of active devices.

---

### INFO-4: `_tasks` List Exposed as Direct Reference

- **Severity:** Informational
- **File:** `lib/providers/task_provider.dart:11-12`
- **Description:** The `tasks` getter returns a direct reference to the internal list. Any consumer could modify it (e.g., `provider.tasks.clear()`). Not exploitable in practice since all consumers are internal UI code.
- **Recommended Fix:** Optional -- return `List.unmodifiable(_tasks)` for strict encapsulation.

---

### INFO-5: `assert` in Production Code Path

- **Severity:** Informational
- **File:** `lib/data/database_helper.dart:531`
- **Code:**
  ```dart
  default:
    assert(false, 'Unknown repeat interval: $repeatInterval');
    offset = const Duration(days: 1);
  ```
- **Description:** `assert` is stripped in release builds, so an unknown repeat interval silently defaults to 1 day. The fallback is safe, but this could mask bugs. The value in the assert message is a controlled string from the database, not user-freeform input.

---

### INFO-6: No Logging Statements in Production Code

- **Severity:** Informational (Positive Finding)
- **Description:** A comprehensive search found zero `print()`, `debugPrint()`, or logging calls in the entire `lib/` directory. No data is leaked through logs. This is excellent practice.

---

## Positive Security Findings

1. **SQL Injection: CLEAN.** All 50+ SQL queries in `database_helper.dart` use parameterized `?` placeholders or sqflite's safe `where`/`whereArgs` APIs. No user input is ever concatenated into SQL strings. Recursive CTE queries are properly parameterized at entry points. Dynamic `IN (...)` clauses use the safe `taskIds.map((_) => '?').join(',')` pattern.

2. **No XSS-like Issues.** Flutter's `Text` widget renders content as plain text -- no HTML/JS interpretation. No `WebView` or HTML rendering widgets are used.

3. **No Sensitive Data Stored.** The data model contains only task names, URLs, timestamps, and integer flags. No passwords, tokens, API keys, PII, or credentials anywhere in the schema or SharedPreferences.

4. **No Network Communication in Release.** The main AndroidManifest.xml has no `INTERNET` permission. The `debug` and `profile` manifests correctly add it for Flutter DevTools only.

5. **File Picker for Import.** The backup import uses the OS file picker (not a text input for file paths), eliminating path traversal risks.

6. **No Dependency Overrides or Git Dependencies.** All packages come from pub.dev with SHA256 integrity hashes in `pubspec.lock`.

7. **Signing Keystore Properly Gitignored.** Both `upload-keystore.jks` and `key.properties` are in `.gitignore`.

---

## OWASP Mobile Top 10 Assessment

| Category | Status | Notes |
|----------|--------|-------|
| M1: Improper Credential Usage | N/A | App has no authentication or credentials |
| M2: Inadequate Supply Chain Security | **Action needed** | `file_picker` has known CVEs (HIGH-1) |
| M3: Insecure Authentication/Authorization | N/A | App has no auth |
| M4: Insufficient Input/Output Validation | **Action needed** | URL scheme validation missing (MED-1, MED-2) |
| M5: Insecure Communication | Pass | No network communication in release; cleartext blocked by default |
| M6: Inadequate Privacy Controls | Pass | No PII beyond task names; appropriate for threat model |
| M7: Insufficient Binary Protections | **Action needed** | No R8/ProGuard obfuscation (MED-5) |
| M8: Security Misconfiguration | Minor | `allowBackup` not explicitly disabled (LOW-8) |
| M9: Insecure Data Storage | Pass | Data is task names/URLs only; sandboxed on Android |
| M10: Insufficient Cryptography | N/A | App does not use cryptography |

---

## Priority Action Items

| Priority | Finding | Effort |
|----------|---------|--------|
| **HIGH** | Update `file_picker` to 10.3.10+ (CVE patches) | Medium (breaking changes) |
| **MEDIUM** | Add URL scheme allowlist (`http`/`https`) to both launch points | Low |
| **MEDIUM** | Add backup import validation (size limit, trigger/view check, version check) | Low |
| **MEDIUM** | Enable R8 code shrinking for Android release builds | Medium |
| **LOW** | Replace `int.parse` with `int.tryParse` in Today's 5 | Trivial |
| **LOW** | Add `maxLength` to task name inputs | Trivial |
| **LOW** | Add `android:allowBackup="false"` | Trivial |
| **LOW** | Update `share_plus` to latest | Medium (breaking changes) |

---

## Round 2 (2026-02-16)

### Previous Round Verification

**Fixed (9 of 17):**
- [x] MED-1: URL scheme validation in leaf detail — verified fixed. New `isAllowedUrl()` utility in `display_utils.dart:17-22` with http/https allowlist. Used at `leaf_task_detail.dart:49`.
- [x] MED-2: URL scheme validation in AppBar — verified fixed. Same `isAllowedUrl()` check at `task_list_screen.dart:735`.
- [x] MED-3: Minimal schema validation on DB import — verified fixed. `_validateBackup()` at `database_helper.dart:172-214` now checks: file size, all 3 expected tables, schema version 1-11, no triggers/views.
- [x] MED-4: No file size limit on import — verified fixed. 100 MB limit at `database_helper.dart:166,174-177`.
- [x] LOW-1: No URL validation on save — verified fixed. `showEditUrlDialog` checks `isAllowedUrl()` at `leaf_task_detail.dart:102,130`. Auto-prepends `https://` via `normalizeUrl()`.
- [x] LOW-2: No input length limits (single-task) — verified fixed. `maxLength: 500` at `add_task_dialog.dart:48` and `task_list_screen.dart:207` (rename dialog).
- [x] LOW-3: Malicious triggers/views — verified fixed. Trigger/view check at `database_helper.dart:204-209`.
- [x] LOW-5: `int.parse` without error handling — verified fixed. `int.tryParse` with `.whereType<int>()` at `todays_five_screen.dart:47,49`.
- [x] LOW-8: Missing `android:allowBackup="false"` — verified fixed. Present at `AndroidManifest.xml:6`.

**Not fixed (5 of 17):**
- [ ] HIGH-1: `file_picker` still at 8.3.7 (pubspec.yaml specifies `^8.1.7`, lock file has `8.3.7`). CVE patches are in 10.3.9+.
- [ ] MED-5: No R8/ProGuard — `build.gradle.kts:51-57` still has no `isMinifyEnabled = true`.
- [ ] LOW-4: No pre-import backup of existing data — `importDatabase` still overwrites directly.
- [ ] LOW-9: Release signing silently falls back to debug key.
- [ ] LOW-10: `firstWhere` without `orElse` — still present at `task_provider.dart:98, 176, 187`.

**Accepted / Deferred (3 of 17):**
- LOW-6: Unencrypted DB at rest — accepted for threat model.
- LOW-7: Unencrypted backup export — accepted for threat model.
- LOW-11: `share_plus` outdated (10.1.4 vs 12.x) — deferred, no CVEs.

### Findings

No new critical or high findings.

#### MED-6: Brain Dump Dialog Has No Per-Line or Total Length Limits

- **Severity:** Medium
- **File:** `lib/widgets/brain_dump_dialog.dart:67-77`
- **Code:**
  ```dart
  TextField(
    controller: _controller,
    maxLines: 8,
    minLines: 4,
    autofocus: true,
    textInputAction: TextInputAction.newline,
    decoration: const InputDecoration(
      hintText: 'Buy groceries\nCall dentist\nFinish report\n...',
      border: OutlineInputBorder(),
    ),
  ),
  ```

**Description:** While the single-task `AddTaskDialog` was fixed with `maxLength: 500` (LOW-2), the brain dump dialog still has no input limits. A user could paste thousands of lines or megabyte-length strings, each of which becomes a separate task and DB INSERT. This creates two risks:
1. **Performance DoS**: Pasting 10,000+ lines triggers 10,000 INSERTs in a single transaction, potentially freezing the UI.
2. **Per-line length**: Individual lines have no 500-char cap, so extremely long task names bypass the limit enforced elsewhere.

**Recommended Fix:**
```dart
TextField(
  controller: _controller,
  maxLines: 8,
  minLines: 4,
  maxLength: 25000, // ~50 lines of 500 chars
  decoration: const InputDecoration(
    counterText: '', // hide counter
    // ...
  ),
),
```
And in `_parseNames()`, truncate each line:
```dart
.map((l) => l.trim().length > 500 ? l.trim().substring(0, 500) : l.trim())
```

---

#### LOW-12: URL Text Field Has No `maxLength`

- **Severity:** Low
- **File:** `lib/widgets/leaf_task_detail.dart:92-99`
- **Code:**
  ```dart
  TextField(
    controller: controller,
    decoration: const InputDecoration(
      hintText: 'https://...',
      border: OutlineInputBorder(),
    ),
    keyboardType: TextInputType.url,
    autofocus: true,
  ),
  ```

**Description:** The URL input dialog has no `maxLength`. A multi-megabyte string pasted into the URL field would be stored in the database and displayed in tooltip text on the task card. While URLs are normalized and scheme-validated, extreme lengths are not checked.

**Recommended Fix:** Add `maxLength: 2048` (standard URL length limit) to the URL TextField.

---

#### LOW-13: `normalizeUrl` May Save Non-URL Strings as URLs

- **Severity:** Low
- **File:** `lib/utils/display_utils.dart:9-14`
- **Code:**
  ```dart
  String? normalizeUrl(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final trimmed = raw.trim();
    if (!trimmed.contains('://')) return 'https://$trimmed';
    return trimmed;
  }
  ```

**Description:** `normalizeUrl` auto-prepends `https://` to any string without `://`. Typing random text like `hello world` becomes `https://hello world`, which passes `isAllowedUrl` (scheme is `https`) and gets stored in the database. While this is harmless (it will fail to open in a browser), it means the URL field can contain garbage data that appears as a valid link in the UI.

**Recommended Fix:** After normalization, validate that the result is a parseable URL with a host:
```dart
final normalized = ...;
final uri = Uri.tryParse(normalized);
if (uri == null || uri.host.isEmpty) return null;
return normalized;
```

---

#### INFO-7: `SnackBar` Uses Non-Standard `persist` Parameter

- **Severity:** Informational
- **Files:** Throughout `task_list_screen.dart`, `todays_five_screen.dart`, `backup_service.dart`, `completed_tasks_screen.dart`
- **Description:** All SnackBar constructors pass `persist: false`. Flutter's `SnackBar` does not have a `persist` parameter. This appears to be silently ignored (Dart named parameters on constructors can be ignored if they match an extension or the class accepts them). If this is a custom extension, it should be documented. If not, it's dead code.

---

### Positive Security Findings

1. **URL scheme validation implemented well.** The `isAllowedUrl()` and `normalizeUrl()` utilities in `display_utils.dart` are clean, centralized, and used consistently across all three code paths (leaf detail launch, AppBar launch, and save dialog). Defense-in-depth: validation at both save time and launch time.

2. **Backup import validation is thorough.** The `_validateBackup` method now checks 5 properties (file size, SQLite validity, table presence, schema version range, trigger/view absence). Error messages are constructive without leaking internal details.

3. **SQL injection remains clean.** All new/modified queries continue to use parameterized `?` placeholders. The dynamic `IN (...)` pattern continues to use the safe `taskIds.map((_) => '?').join(',')` idiom throughout.

4. **No new logging statements.** The codebase remains free of `print()`, `debugPrint()`, or logging calls.

5. **`allowBackup="false"` properly set.** The Android manifest now explicitly disables ADB backup.

6. **SharedPreferences parsing is now robust.** `int.tryParse` with `.whereType<int>()` gracefully handles corrupt data.

### OWASP Mobile Top 10 Assessment (Round 2 Update)

| Category | Status | Notes |
|----------|--------|-------|
| M1: Improper Credential Usage | N/A | App has no authentication or credentials |
| M2: Inadequate Supply Chain Security | **Still action needed** | `file_picker` 8.3.7 still has known CVEs (HIGH-1 unfixed) |
| M3: Insecure Authentication/Authorization | N/A | App has no auth |
| M4: Insufficient Input/Output Validation | **Improved** | URL scheme validation fixed; brain dump dialog still unbounded (MED-6) |
| M5: Insecure Communication | Pass | No network communication in release |
| M6: Inadequate Privacy Controls | Pass | No PII beyond task names |
| M7: Insufficient Binary Protections | **Still action needed** | No R8/ProGuard (MED-5 unfixed) |
| M8: Security Misconfiguration | **Improved** | `allowBackup="false"` fixed; debug signing fallback remains (LOW-9) |
| M9: Insecure Data Storage | Pass | Data is task names/URLs only; sandboxed on Android |
| M10: Insufficient Cryptography | N/A | App does not use cryptography |

### Remaining Priority Action Items

| Priority | Finding | Status |
|----------|---------|--------|
| **HIGH** | HIGH-1: Update `file_picker` to 10.3.10+ | **Still open** |
| **MEDIUM** | MED-5: Enable R8 code shrinking | **Still open** |
| **MEDIUM** | MED-6: Add limits to brain dump dialog | **New** |
| **LOW** | LOW-4: Pre-import backup of existing DB | **Still open** |
| **LOW** | LOW-9: Warn on debug signing fallback | **Still open** |
| **LOW** | LOW-10: `firstWhere` without `orElse` | **Still open** |
| **LOW** | LOW-12: Add `maxLength` to URL field | **New** |
| **LOW** | LOW-13: Validate URL host after normalization | **New** |

---

## Round 3 (2026-02-25)

**Scope:** Full review of new cloud sync layer (Google Sign-In + Firestore REST APIs), plus verification of all Round 1/2 fixes.

### Previous Round Verification

**Round 1 findings — all 8 outstanding items from Round 2 resolved:**
- [x] HIGH-1: `file_picker` updated to 10.3.10 — verified in `pubspec.yaml` and `pubspec.lock`
- [x] MED-5: R8 code shrinking enabled — `build.gradle.kts:55-56` has `isMinifyEnabled = true` and `isShrinkResources = true`
- [x] MED-6: Brain dump dialog limits — `brain_dump_dialog.dart:72` has `maxLength: 25000`, and `_parseNames()` at line 34 truncates each line to 500 chars
- [x] LOW-4: Pre-import backup — `database_helper.dart:314-317` copies `.db` to `.db.bak` before overwriting
- [x] LOW-9: Debug signing fallback warning — `build.gradle.kts:19` logs `logger.warn("WARNING: key.properties not found...")`
- [x] LOW-10: `firstWhere` without `orElse` — all three call sites at `task_provider.dart:108,188,201` now have explicit `orElse` clauses. They still throw `StateError` but with descriptive messages, and the `_currentParent?.id == taskId` short-circuit above each reduces the likelihood of reaching the throw path
- [x] LOW-12: URL maxLength — `leaf_task_detail.dart:102` has `maxLength: 2048`
- [x] LOW-13: normalizeUrl host validation — `display_utils.dart:19` checks `uri.host.contains('.')`

**Round 1/2 accepted items — status unchanged:**
- LOW-6: Unencrypted DB at rest — still accepted for threat model
- LOW-7: Unencrypted backup export — still accepted for threat model
- LOW-11: `share_plus` outdated — **resolved: dependency removed** (no longer in `pubspec.yaml`)

**Previously correct positive findings now invalidated by sync layer:**
- ~~Positive Finding #3 "No Sensitive Data Stored"~~ — Firebase refresh token is now stored in SharedPreferences
- ~~Positive Finding #4 "No Network Communication in Release"~~ — Sync layer adds network calls; INTERNET permission is now merged in via `google_sign_in`/`http` plugin manifests
- ~~INFO-6 "No Logging Statements"~~ — 8 `debugPrint()` calls added in `auth_service.dart` and `auth_provider.dart`

### Findings

#### HIGH-2: Firebase Refresh Token Stored in Plaintext SharedPreferences

- **Severity:** High
- **File:** `lib/services/auth_service.dart:300-303`
- **Code:**
  ```dart
  Future<void> _persistTokens(SharedPreferences prefs) async {
    if (_firebaseRefreshToken != null) {
      await prefs.setString(_prefsKeyRefreshToken, _firebaseRefreshToken!);
    }
  }
  ```

**Description:** The Firebase refresh token is stored in SharedPreferences without encryption. Refresh tokens are long-lived credentials that can generate new ID tokens indefinitely, granting full read/write access to the user's Firestore data (all tasks, relationships, dependencies).

- **Android:** SharedPreferences are stored in the app's sandboxed `/data/data/` directory. Requires root access to read — acceptable on Android.
- **Linux:** `shared_preferences_linux` stores data in `~/.local/share/com.taskroulette.task_roulette/shared_preferences.json`, a plain JSON file readable by any process running as the same user. Any malware, browser extension with file access, or another local app could read the refresh token.

**Impact:** Token theft → full access to the user's cloud task data, including ability to read, modify, and delete all synced tasks.

**Recommended Fix:**
On Linux, use the system keyring via `flutter_secure_storage` (which uses libsecret/GNOME Keyring):
```dart
// Store refresh token securely
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
final _secureStorage = FlutterSecureStorage();
await _secureStorage.write(key: 'auth_refresh_token', value: token);
```
On Android, `flutter_secure_storage` uses Android Keystore. This provides encryption at rest on both platforms.

---

#### MED-7: `debugPrint` Statements Leak Auth Error Details to System Log

- **Severity:** Medium
- **File:** `lib/services/auth_service.dart:87,164,204,214,256,279`
- **Code (worst case):**
  ```dart
  debugPrint('AuthService: Firebase token exchange failed: ${response.statusCode} ${response.body}');
  ```

**Description:** The auth service contains 6 `debugPrint()` calls that log authentication error details. Unlike `assert`, `debugPrint` is NOT stripped in release builds — it calls `print()` which writes to the system log. On Android, this goes to logcat, readable by any app with `READ_LOGS` permission (Android <4.1) or via `adb logcat`. The logged data includes:
- Firebase API response bodies (error codes, project identifiers)
- Google Sign-In error messages (could include account details)
- Token refresh failure reasons

The `auth_provider.dart:53` also logs: `debugPrint('AuthProvider: token refresh failed: $e')`.

This breaks the previous positive finding (INFO-6) that the codebase had zero logging statements.

**Recommended Fix:** Remove all `debugPrint` calls from auth code. If debug logging is needed, gate it:
```dart
if (kDebugMode) {
  debugPrint('AuthService: ...');
}
```
`kDebugMode` is a compile-time constant that is `false` in release builds, so the entire block is tree-shaken.

---

#### MED-8: Remote Sync Bypasses DAG Cycle Detection

- **Severity:** Medium
- **File:** `lib/data/database_helper.dart:1632-1644, 1658-1667`
- **Code:**
  ```dart
  Future<void> upsertRelationshipFromRemote(String parentSyncId, String childSyncId) async {
    // ...
    await db.rawInsert(
      'INSERT OR IGNORE INTO task_relationships (parent_id, child_id) VALUES (?, ?)',
      [parentId, childId],
    );
  }
  ```

**Description:** When pulling relationships and dependencies from Firestore, the sync layer inserts them directly with `INSERT OR IGNORE` without calling `hasPath()` or `hasDependencyPath()` for cycle detection. The local DAG invariant (no cycles) is a core safety property — the recursive CTE queries in `hasPath` and navigation rely on it. Sources of corrupted data:
1. A bug in a future version of the app that pushes invalid data
2. Direct Firestore edits (via Firebase console or API)
3. Race conditions during concurrent sync from multiple devices

**Impact:** A cycle in the relationship graph could cause infinite loops in recursive CTE queries, hanging the app. A cycle in the dependency graph would create unresolvable blockers.

**Recommended Fix:** After pulling all relationships, validate the DAG:
```dart
for (final rel in remoteRels) {
  // Check if adding this would create a cycle
  final childId = await _db.getTaskIdBySyncId(rel.childSyncId);
  final parentId = await _db.getTaskIdBySyncId(rel.parentSyncId);
  if (childId != null && parentId != null) {
    final wouldCycle = await _db.hasPath(childId, parentId);
    if (!wouldCycle) {
      await _db.upsertRelationshipFromRemote(rel.parentSyncId, rel.childSyncId);
    }
  }
}
```

---

#### MED-9: No Validation of Remote Task Field Sizes

- **Severity:** Medium
- **File:** `lib/services/firestore_service.dart:346-369`
- **Code:**
  ```dart
  return Task(
    name: _stringField(fields, 'name') ?? '',
    // ... no length checks on any field
  );
  ```

**Description:** `taskFromFirestoreDoc` deserializes task data from Firestore documents without validating field sizes. Firestore documents can be up to 1MB. A corrupted or maliciously modified cloud document with an extremely long `name` (e.g., 500KB) or `url` field would be:
1. Stored in the local SQLite database, causing bloat
2. Rendered in `Text` widgets in the grid view, causing layout thrash and jank
3. Passed to `TextEditingController` in rename dialogs, potentially causing memory issues

This is especially concerning because the data comes from a network source the user doesn't directly control after initial sign-in.

**Recommended Fix:** Truncate fields during deserialization:
```dart
name: (_stringField(fields, 'name') ?? '').substring(0, min(500, name.length)),
url: urlField != null && urlField.length <= 2048 ? urlField : null,
```

---

#### MED-10: Sync Error Messages Expose Internal Details to UI

- **Severity:** Medium
- **File:** `lib/services/sync_service.dart:126,174,231,309,399`
- **Code:**
  ```dart
  _authProvider.setSyncStatus(SyncStatus.error, error: e.toString());
  ```

**Description:** Raw exception messages (including `FirestoreException` with HTTP status codes and response bodies, `SocketException` with server addresses, and other internal errors) are passed to the UI via `setSyncStatus`. These are displayed in the profile bottom sheet's sync status row (`profile_icon.dart:368`). Example message a user would see: `"FirestoreException: Push tasks failed: 403 {"error":{"code":403,"message":"Missing or insufficient permissions.","status":"PERMISSION_DENIED"}}"`.

**Recommended Fix:** Map exceptions to user-friendly messages:
```dart
} catch (e) {
  final message = e is FirestoreException
      ? 'Sync failed — check your connection'
      : 'Sync error — try again later';
  _authProvider.setSyncStatus(SyncStatus.error, error: message);
}
```

---

#### LOW-14: INTERNET Permission Now Present in Release Builds

- **Severity:** Low (informational correction)
- **File:** `android/app/src/main/AndroidManifest.xml`

**Description:** The previous security review (Round 1, Positive Finding #4) stated "No Network Communication in Release. The main AndroidManifest.xml has no INTERNET permission." This is now incorrect. The `google_sign_in`, `http`, and `googleapis_auth` packages declare INTERNET permission in their plugin manifests, which are merged into the release APK by the Android build system. The app now communicates with:
- `identitytoolkit.googleapis.com` (Firebase Auth)
- `securetoken.googleapis.com` (token refresh)
- `firestore.googleapis.com` (data sync)
- Google OAuth endpoints (sign-in)

**Recommended Fix:** Add `<uses-permission android:name="android.permission.INTERNET"/>` to the main `AndroidManifest.xml` for transparency and self-documentation. It's already present via merging, but explicitly declaring it makes the app's capabilities clear.

---

#### LOW-15: Firestore Security Rules Not Version-Controlled

- **Severity:** Low
- **Files:** No `firestore.rules` or `firebase.json` in the repository

**Description:** The app reads and writes to Firestore paths: `/users/{uid}/tasks/*`, `/users/{uid}/relationships/*`, `/users/{uid}/dependencies/*`. Firestore Security Rules must ensure that only the authenticated user can access their own data (`request.auth.uid == uid`). Without the rules in the repository, there's no visibility into the current production rules, no code review for rule changes, and no way to verify correct access controls.

**Recommended Fix:** Initialize Firebase in the repo and add security rules:
```bash
firebase init firestore
```
Minimal rules file (`firestore.rules`):
```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{userId}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
  }
}
```

---

#### LOW-16: No HTTP Request Timeout on Sync/Auth API Calls

- **Severity:** Low
- **Files:** `lib/services/firestore_service.dart` (all `http.post`/`http.get` calls), `lib/services/auth_service.dart:266,288`

**Description:** All HTTP requests use the default `http` package client with no explicit timeout. A hung server connection (e.g., DNS resolution stall, firewall drop without RST) would block the sync operation indefinitely. Since `SyncService._syncing` is a mutex flag, a single stuck request prevents all future sync operations until the app is restarted.

**Recommended Fix:** Use `http.Client` with a timeout, or wrap calls:
```dart
final response = await http.post(url, ...).timeout(
  const Duration(seconds: 30),
  onTimeout: () => http.Response('', 408),
);
```

---

#### LOW-17: `NetworkImage` Loads Profile Photo Without Scheme Validation

- **Severity:** Low
- **File:** `lib/widgets/profile_icon.dart:37-39, 292-294`
- **Code:**
  ```dart
  backgroundImage: photoUrl != null && photoUrl.isNotEmpty
      ? NetworkImage(photoUrl)
      : null,
  ```

**Description:** The user's Google profile photo URL is loaded via `NetworkImage` without validating the URL scheme. While Google always returns HTTPS URLs for profile photos, the URL is stored in SharedPreferences and restored on silent sign-in. If SharedPreferences were tampered with (see HIGH-2), a `file://` or other scheme could be loaded. On its own this is low risk since `NetworkImage` only supports HTTP/S, but it's defense-in-depth to validate.

**Recommended Fix:** Validate scheme before using:
```dart
backgroundImage: photoUrl != null && photoUrl.isNotEmpty && isAllowedUrl(photoUrl)
    ? NetworkImage(photoUrl)
    : null,
```

---

#### INFO-8: User Info Stored in SharedPreferences

- **Severity:** Informational
- **File:** `lib/services/auth_service.dart:305-318`

**Description:** User display name, email, and photo URL are stored in SharedPreferences for silent sign-in restoration. On Linux, these are in a plain JSON file. This is PII (email address, name). Not a vulnerability given the threat model (single-user desktop app), but worth noting for data inventory purposes.

---

#### INFO-9: Firebase Web Client ID Hardcoded as Default Value

- **Severity:** Informational
- **File:** `lib/services/auth_service.dart:42-43`
- **Code:**
  ```dart
  static const _webClientId = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
    defaultValue: '1009352820106-uigevs5kld7t51s1gol27l7n85m2vp36.apps.googleusercontent.com',
  );
  ```

**Description:** The Google OAuth web client ID is hardcoded as a `defaultValue`. This is the same client ID already public in `google-services.json`. OAuth client IDs are designed to be public — they identify the app, not authenticate it. However, having it as a `defaultValue` means the `--dart-define` override is effectively unused for this value on Android.

---

### Positive Security Findings

1. **SQL injection remains clean.** All queries in the new sync-related database methods (`upsertFromRemote`, `upsertRelationshipFromRemote`, etc.) use parameterized queries with `?` placeholders. The dynamic `IN (...)` pattern continues to use the safe `taskIds.map((_) => '?').join(',')` idiom.

2. **Firebase Auth token management is sound.** Token refresh is attempted before expiry (1-minute buffer at `auth_service.dart:59`). On permanent refresh failure (revoked token), the user is signed out (`auth_provider.dart:47`). Transient failures (network errors) don't sign out the user.

3. **Sync queue provides reliable at-least-once delivery.** Queue entries are only deleted after successful remote operations (`sync_service.dart:305`), surviving partial push failures. This is a good distributed systems pattern.

4. **OAuth uses list-based process arguments (no shell injection).** `Process.start('xdg-open', [url])` at `auth_service.dart:231` passes the URL as a list element, not via shell interpolation. Safe against command injection.

5. **Firestore data isolation by user ID.** All Firestore paths are scoped to `/users/{uid}/...`, and the UID comes from Firebase Auth (not user input). Cross-user data access is prevented at the API path level (assuming correct Firestore Security Rules — see LOW-15).

6. **All previous Round 1/2 fixes verified intact.** URL scheme validation, backup import validation, input length limits, `allowBackup="false"`, R8 shrinking, brain dump limits, pre-import backup — all still in place and working correctly.

7. **Sync state uses server-authoritative timestamps.** `updated_at` fields use `DateTime.now().millisecondsSinceEpoch` at mutation time, and the pull query filters by `updated_at > lastSyncAt`. Last-write-wins with remote-preferred conflict resolution is a reasonable strategy for this app's single-user-multi-device model.

### OWASP Mobile Top 10 Assessment (Round 3 Update)

| Category | Status | Notes |
|----------|--------|-------|
| M1: Improper Credential Usage | **Action needed** | Firebase refresh token in plaintext SharedPreferences (HIGH-2) |
| M2: Inadequate Supply Chain Security | **Pass** | `file_picker` updated to 10.3.10; all deps from pub.dev with SHA256 hashes |
| M3: Insecure Authentication/Authorization | **Minor** | Auth implementation is sound, but Firestore rules not version-controlled (LOW-15) |
| M4: Insufficient Input/Output Validation | **Action needed** | Remote sync data not validated for size or DAG integrity (MED-8, MED-9) |
| M5: Insecure Communication | **Pass** | All API calls use HTTPS; no cleartext traffic |
| M6: Inadequate Privacy Controls | **Minor** | User email/name stored in plaintext SharedPreferences on Linux (INFO-8) |
| M7: Insufficient Binary Protections | **Pass** | R8/ProGuard now enabled |
| M8: Security Misconfiguration | **Minor** | INTERNET permission present but not explicitly declared in main manifest (LOW-14) |
| M9: Insecure Data Storage | **Action needed** | Refresh token in plaintext on Linux (HIGH-2) |
| M10: Insufficient Cryptography | N/A | App does not use custom cryptography |

### Remaining Priority Action Items

| Priority | Finding | Effort | Status |
|----------|---------|--------|--------|
| **HIGH** | HIGH-2: Encrypt refresh token (use `flutter_secure_storage`) | Medium | **New** |
| **MEDIUM** | MED-7: Gate `debugPrint` behind `kDebugMode` | Low | **New** |
| **MEDIUM** | MED-8: Add cycle detection to remote sync pull | Medium | **New** |
| **MEDIUM** | MED-9: Validate remote task field sizes | Low | **New** |
| **MEDIUM** | MED-10: Sanitize sync error messages for UI | Low | **New** |
| **LOW** | LOW-14: Explicitly declare INTERNET permission | Trivial | **New** |
| **LOW** | LOW-15: Version-control Firestore Security Rules | Low | **New** |
| **LOW** | LOW-16: Add HTTP request timeouts | Low | **New** |
| **LOW** | LOW-17: Validate profile photo URL scheme | Trivial | **New** |
