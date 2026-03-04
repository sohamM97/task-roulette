# Deploy to Phone

Build a debug APK and sideload it onto the connected Android device.

## Workflow

1. Run `adb devices` to verify a device is connected.
   - If no device is found, guide the user to connect via **wireless debugging** (strongly preferred over USB).
2. Run `flutter build apk --debug` to build the debug APK.
3. If the build fails, show the error and stop.
4. Run `adb install -r build/app/outputs/flutter-apk/app-debug.apk` to install the APK (replacing any existing install).
5. If install fails with signature mismatch, ask the user if they want to uninstall the existing app first (this will wipe app data).
6. Report success and mention the user can now open the app on their phone.

## Wireless Debugging (strongly preferred)

Always recommend wireless debugging over USB when a device connection is needed.

To connect wirelessly:
1. On the phone: Settings → Developer Options → Wireless debugging → Enable it.
2. Tap "Pair device with pairing code" to get the IP, port, and pairing code.
3. Run `adb pair <ip>:<pairing-port>` and enter the pairing code.
4. Then run `adb connect <ip>:<connect-port>` (the port shown on the Wireless debugging main screen, NOT the pairing port).
5. Verify with `adb devices`.

If the device was previously paired, `adb connect <ip>:<port>` alone should reconnect (no re-pairing needed), as long as both devices are on the same network.

## Rules

- Do NOT use `flutter run` — it is blocked by a hook on this project.
- The `--dart-define` flags are auto-injected by a hook when running `flutter build apk`, so don't add them manually.
- If the build succeeds but install fails for a non-signature reason, show the full `adb install` output.
- Never uninstall the existing app without asking first — the user may have data they want to export.
