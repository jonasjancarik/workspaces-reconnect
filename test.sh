#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly SOURCE="$SCRIPT_DIR/WorkSpacesReconnect.swift"

for script in "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/uninstall.sh"; do
    zsh -n "$script"

    if grep -Eq 'local[[:space:]]+path=' "$script"; then
        print -u2 "Shell regression: zsh's special path variable must not be shadowed."
        exit 1
    fi
done

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/workspaces-reconnect-test.XXXXXX")"
temporary_binary="$temporary_directory/workspaces-reconnect"
cleanup() {
    /bin/rm -rf "$temporary_directory"
}
trap cleanup EXIT

export CLANG_MODULE_CACHE_PATH="$temporary_directory/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$temporary_directory/swift-module-cache"

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

print "security regression checks passed"
