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
