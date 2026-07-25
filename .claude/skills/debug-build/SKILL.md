---
name: debug-build
description: Deploy to Phone. Use when the user wants to build and install the app on their phone.
---

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

**Ask about pairing status FIRST — don't assume either way.** Before giving any
connect instructions, have the user open **Settings → Developer Options →
Wireless debugging** on the phone. That screen shows, top to bottom: a
**"Use wireless debugging"** toggle, **"Device name"**, **"IP address and
port"** (e.g. `192.168.1.5:42173`), then **"Pair device with QR code"**,
**"Pair device with pairing code"**, and finally a **"Paired devices"** section
at the bottom listing this machine by its hostname (e.g.
`soham@soham-Dell-...`), with **"Currently connected"** underneath when a live
connection exists.

Ask in ONE message for both: (a) whether this machine is listed under **"Paired
devices"**, and (b) the **"IP address and port"** — the user may answer with the
full `<ip>:<port>` or just the port, whichever is easier; the port rotates every
session while the IP usually doesn't, so a bare port is a perfectly normal
answer. Pair it with the last known IP from memory, and only ask for the IP
explicitly if there's no saved one or the connect fails. Then branch:

**Already paired** — no re-pairing needed:
1. Run `adb connect <ip>:<port>` with the "IP address and port" value (the port changes every session; the IP usually doesn't).
2. Verify with `adb devices`.

**Not paired** (or the connect above fails):
1. On the phone, tap **"Pair device with pairing code"** — it opens a dialog with its own IP, a *pairing* port, and a 6-digit code.
2. Run `adb pair <ip>:<pairing-port>` and enter the pairing code.
3. Then run `adb connect <ip>:<connect-port>` using the **"IP address and port"** value from the main screen — NOT the pairing port (they differ).
4. Verify with `adb devices`.

When no device is connected, check your memory for the last known IP. Try `adb connect <saved-ip>:<port>` with the user-provided port. If the connection fails, ask the user to verify the IP hasn't changed. When a connection succeeds, save the IP to memory for next time.

## Rules

- Do NOT use `flutter run` — it is blocked by a hook on this project.
- The `--dart-define` flags are auto-injected by a hook when running `flutter build apk`, so don't add them manually.
- If the build succeeds but install fails for a non-signature reason, show the full `adb install` output.
- Never uninstall the existing app without asking first — the user may have data they want to export.
