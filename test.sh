#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly SOURCE="$SCRIPT_DIR/WorkSpacesReconnect.swift"
readonly INSTALLER="$SCRIPT_DIR/install.sh"
readonly VERIFIER="$SCRIPT_DIR/verify.sh"
readonly PLIST_TEMPLATE="$SCRIPT_DIR/com.jonasjancarik.workspaces-reconnect.plist"

for script in "$INSTALLER" "$SCRIPT_DIR/uninstall.sh" "$VERIFIER"; do
    zsh -n "$script"

    if grep -Eq 'local[[:space:]]+path=' "$script"; then
        print -u2 "Shell regression: zsh's special path variable must not be shadowed."
        exit 1
    fi
done

if grep -Fq 'plutil -replace ProgramArguments.0' "$INSTALLER"; then
    print -u2 "LaunchAgent regression: plutil inserts instead of replacing array item zero."
    exit 1
fi

if ! grep -Fq 'plutil -remove ProgramArguments.0 "$temporary_plist"' "$INSTALLER" \
    || ! grep -Fq 'plutil -insert ProgramArguments.0 -string "$BINARY" "$temporary_plist"' "$INSTALLER"; then
    print -u2 "LaunchAgent regression: installer must remove the placeholder before inserting the binary."
    exit 1
fi

bootout_line="$(grep -nF 'launchctl bootout "$DOMAIN/$LABEL"' "$INSTALLER" | head -n 1)"
cleanup_prompt_line="$(grep -nF 'Press Return when no old workspaces-reconnect rows remain' "$INSTALLER" | head -n 1)"
if [[ -z "$bootout_line" || -z "$cleanup_prompt_line" \
    || "${bootout_line%%:*}" -ge "${cleanup_prompt_line%%:*}" ]]; then
    print -u2 "Accessibility regression: stop the old watcher before removing its permission rows."
    exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/workspaces-reconnect-test.XXXXXX")"
temporary_binary="$temporary_directory/workspaces-reconnect"
temporary_plist="$temporary_directory/com.jonasjancarik.workspaces-reconnect.plist"
cleanup() {
    /bin/rm -rf "$temporary_directory"
}
trap cleanup EXIT

export CLANG_MODULE_CACHE_PATH="$temporary_directory/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$temporary_directory/swift-module-cache"

cp "$PLIST_TEMPLATE" "$temporary_plist"
expected_program="$temporary_directory/Application Support/workspaces-reconnect"
plutil -remove ProgramArguments.0 "$temporary_plist"
plutil -insert ProgramArguments.0 -string "$expected_program" "$temporary_plist"
if [[ "$(plutil -extract ProgramArguments.0 raw "$temporary_plist")" != "$expected_program" ]] \
    || [[ "$(plutil -extract ProgramArguments.1 raw "$temporary_plist")" != "check" ]] \
    || plutil -extract ProgramArguments.2 raw "$temporary_plist" >/dev/null 2>&1; then
    print -u2 "LaunchAgent regression: generated command must contain exactly the binary and check."
    exit 1
fi

malformed_home="$temporary_directory/malformed-home"
malformed_binary="$malformed_home/Library/Application Support/WorkSpacesReconnect/bin/workspaces-reconnect"
malformed_plist="$malformed_home/Library/LaunchAgents/com.jonasjancarik.workspaces-reconnect.plist"
malformed_output="$temporary_directory/malformed-verification.txt"
mkdir -p "${malformed_binary:h}" "${malformed_plist:h}"
cp /usr/bin/true "$malformed_binary"
cp "$PLIST_TEMPLATE" "$malformed_plist"
plutil -replace ProgramArguments.0 -string "$malformed_binary" "$malformed_plist"
if HOME="$malformed_home" "$VERIFIER" >"$malformed_output" 2>&1; then
    print -u2 "LaunchAgent regression: verification accepted an extra scheduled argument."
    exit 1
fi
if ! grep -Fq "LaunchAgent verification failed:" "$malformed_output"; then
    print -u2 "LaunchAgent regression: verification did not explain the malformed command."
    exit 1
fi

xcrun swiftc \
    -O \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Security \
    "$SOURCE" \
    -o "$temporary_binary"

"$temporary_binary" self-test

if grep -Fq '.post(tap:' "$SOURCE"; then
    print -u2 "Security regression: system-wide keyboard event posting is forbidden."
    exit 1
fi

if grep -Fq 'CGEventSource(stateID: .hidSystemState)' "$SOURCE"; then
    print -u2 "Security regression: synthetic credential events must not inherit live modifiers."
    exit 1
fi

if grep -Fq 'NSPasteboard' "$SOURCE"; then
    print -u2 "Security regression: credentials must never use the system pasteboard."
    exit 1
fi

if grep -Fq 'lastAccessibilityPromptAt' "$SOURCE"; then
    print -u2 "Accessibility regression: the scheduled watcher must not recreate permission rows."
    exit 1
fi

if ! grep -Fq '.postToPid(processIdentifier)' "$SOURCE"; then
    print -u2 "Security regression: credential events must target the verified WorkSpaces process."
    exit 1
fi

if ! grep -Fq 'SecCodeCheckValidity' "$SOURCE"; then
    print -u2 "Security regression: the WorkSpaces process must pass code-signature validation."
    exit 1
fi

if ! grep -Fq 'certificate leaf[field.1.2.840.113635.100.6.1.9]' "$SOURCE"; then
    print -u2 "Compatibility regression: the official Mac App Store signature must be accepted."
    exit 1
fi

if ! grep -Fq 'certificate leaf[subject.OU] = "94KV3E626L"' "$SOURCE"; then
    print -u2 "Security regression: direct downloads must retain Amazon's Team ID requirement."
    exit 1
fi

print "security and LaunchAgent regression checks passed"
