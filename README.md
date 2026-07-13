# WorkSpaces reconnect watcher

> Read this when installing, updating, uninstalling, or debugging the watcher.

A small, deterministic macOS LaunchAgent that keeps the Amazon WorkSpaces desktop client connected. It checks the WorkSpaces accessibility tree every 10 seconds and does not use an LLM, network API, or screenshot model.

The watcher recognizes active sessions, startup progress, disconnected screens, username fields, password fields, and credential errors. Two consecutive actionable detections start a deterministic reconnect flow. Unexpected screens fail closed.

## Security model

- The repository contains no username or password.
- The username is stored as the account name of a generic macOS Keychain item.
- The password is stored as that item's secret data.
- The installer uses Keychain's own password prompt, so the password is not placed in shell history or process arguments.
- The installer explicitly grants the watcher access to its Keychain item. It never uses Keychain's insecure `-A` option, which would grant every application access.
- Credential input is sent directly to the process that owns the confirmed WorkSpaces field. The watcher never emits system-wide keystrokes, so another foreground application cannot receive the username or password.
- The password is typed directly into the confirmed secure field and is never placed on the system pasteboard.
- Before and during input, the watcher verifies Amazon's designated code-signing requirement, confirms that the field belongs to that visible WorkSpaces process, and checks that it remains focused. Any mismatch aborts the attempt.
- Editable fields and registration codes are redacted from diagnostics.
- Accessibility permission is required for the installed executable. Codex or Terminal permission is not inherited by a LaunchAgent.

The watcher can safely reconnect while another application is in the foreground. It targets WorkSpaces by process ID and does not take keyboard focus away from the application you are using.

The Keychain service name is `codex-amazon-workspaces`. It is an identifier, not a secret, and is retained for compatibility with existing installations.

## Requirements

- macOS
- Amazon WorkSpaces desktop client
- Xcode Command Line Tools (`xcrun swiftc`)

## Install

Clone the repository, then run:

```bash
./install.sh
```

The installer:

1. Builds and self-tests the Swift executable locally.
2. Asks for the WorkSpaces username.
3. Invokes a secure Keychain prompt for the password.
4. Installs the executable under `~/Library/Application Support/WorkSpacesReconnect/bin/`.
5. Generates and loads a per-user LaunchAgent that runs every 10 seconds.
6. Opens Accessibility settings and waits for `workspaces-reconnect` to be enabled.
7. Verifies Accessibility, Keychain access, UI classification, and the LaunchAgent from the real launchd context.

No compiled binary, generated plist, credential, log, or state file needs to be committed.

## Update

Run `./install.sh` again. Rebuilding changes the unsigned local executable's macOS privacy identity, so the installer asks you to remove the old `workspaces-reconnect` Accessibility entry and enable the newly registered one. It also refreshes the Keychain trusted-application record.

## Verify

```bash
./verify.sh
```

This runs diagnostics and a credential-read check as one-shot launchd jobs. Running the executable directly from Terminal is not an equivalent permission test.

Additional diagnostics:

```bash
launchctl print gui/$(id -u)/com.jonasjancarik.workspaces-reconnect
tail -f ~/Library/Application\ Support/WorkSpacesReconnect/watcher.log
```

The detector primarily uses the accessibility window description and visible controls. Window dimensions are only a fallback for recognizing a clearly large active session; small windows never trigger login without matching accessibility roles and labels.

The watcher writes transition-only diagnostics for unknown, disconnected, credential-error, or accessibility-unavailable states. Repeated checks of the same screen do not produce duplicate snapshots.

## Uninstall

Remove the LaunchAgent, installed executable, logs, and state while keeping the Keychain credential:

```bash
./uninstall.sh
```

Remove those files and the Keychain credential:

```bash
./uninstall.sh --purge
```

Both forms leave the cloned source directory untouched and open Accessibility settings so its stale privacy entry can be removed manually. They are safe to rerun.

The uninstaller intentionally does not call `tccutil reset Accessibility`, because that would remove Accessibility permission from every application.

## Development

Build and run the source-only tests without installing:

```bash
./test.sh
```

The test compiles the watcher, runs its input-target classification checks, and fails if credential handling regresses to system-wide keyboard events or the system pasteboard.

The equivalent manual build is:

```bash
xcrun swiftc \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Security \
  WorkSpacesReconnect.swift \
  -o workspaces-reconnect
./workspaces-reconnect self-test
```

Do not print, log, or pass the password as a command-line argument. After changing and rebuilding the executable, run `./install.sh` so Keychain and Accessibility permissions are refreshed for the final binary.
