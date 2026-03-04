# Deploy to Phone

Build a debug APK and sideload it onto the connected Android device.

## Workflow

1. Run `adb devices` to verify a device is connected. If none found, tell the user to connect their phone and enable USB debugging.
2. Run `flutter build apk --debug` to build the debug APK.
3. If the build fails, show the error and stop.
4. Run `adb install -r build/app/outputs/flutter-apk/app-debug.apk` to install the APK (replacing any existing install).
5. If install fails with signature mismatch, ask the user if they want to uninstall the existing app first (this will wipe app data).
6. Report success and mention the user can now open the app on their phone.

## Rules

- Do NOT use `flutter run` — it is blocked by a hook on this project.
- The `--dart-define` flags are auto-injected by a hook when running `flutter build apk`, so don't add them manually.
- If the build succeeds but install fails for a non-signature reason, show the full `adb install` output.
- Never uninstall the existing app without asking first — the user may have data they want to export.
