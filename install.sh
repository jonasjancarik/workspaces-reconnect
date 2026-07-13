#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly LABEL="com.jonasjancarik.workspaces-reconnect"
readonly KEYCHAIN_SERVICE="codex-amazon-workspaces"
readonly SCRIPT_DIR="${0:A:h}"
readonly SOURCE="$SCRIPT_DIR/WorkSpacesReconnect.swift"
readonly PLIST_TEMPLATE="$SCRIPT_DIR/$LABEL.plist"
readonly SUPPORT_DIR="$HOME/Library/Application Support/WorkSpacesReconnect"
readonly BIN_DIR="$SUPPORT_DIR/bin"
readonly BINARY="$BIN_DIR/workspaces-reconnect"
readonly LOG_PATH="$SUPPORT_DIR/watcher.log"
readonly STATE_PATH="$SUPPORT_DIR/state.json"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly DOMAIN="gui/$(id -u)"
readonly ACCESSIBILITY_URL="x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

if (( $# != 0 )); then
    print -u2 "usage: ./install.sh"
    exit 64
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    print -u2 "This watcher requires macOS."
    exit 69
fi

for command in xcrun plutil launchctl security open; do
    if ! command -v "$command" >/dev/null; then
        print -u2 "Missing required command: $command"
        exit 69
    fi
done

move_to_trash() {
    local target_path="$1"
    [[ -e "$target_path" ]] || return 0

    if command -v trash >/dev/null; then
        trash "$target_path"
        return
    fi

    mkdir -p "$HOME/.Trash"
    local destination="$HOME/.Trash/${target_path:t}.$(date +%Y%m%d-%H%M%S).$$"
    mv "$target_path" "$destination"
}

run_accessibility_request() {
    local job_label="$LABEL.accessibility.$$"
    local output_file
    output_file="$(mktemp "${TMPDIR:-/tmp}/workspaces-reconnect-accessibility.XXXXXX")"

    launchctl submit \
        -l "$job_label" \
        -o "$output_file" \
        -e "$output_file" \
        -- "$BINARY" request-accessibility

    for _ in {1..50}; do
        [[ -s "$output_file" ]] && break
        sleep 0.1
    done
    launchctl remove "$job_label" >/dev/null 2>&1 || true
    /bin/rm -f "$output_file"
}

mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents"
temporary_binary="$(mktemp "$BIN_DIR/.workspaces-reconnect.XXXXXX")"
temporary_plist="$(mktemp "${TMPDIR:-/tmp}/workspaces-reconnect-plist.XXXXXX")"
cleanup() {
    if [[ -n "${temporary_binary:-}" && -e "$temporary_binary" ]]; then
        /bin/rm -f "$temporary_binary"
    fi
    if [[ -n "${temporary_plist:-}" && -e "$temporary_plist" ]]; then
        /bin/rm -f "$temporary_plist"
    fi
}
trap cleanup EXIT

print "Building the watcher…"
xcrun swiftc \
    -O \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Security \
    "$SOURCE" \
    -o "$temporary_binary"
chmod 755 "$temporary_binary"
"$temporary_binary" self-test

print -n "WorkSpaces username: "
IFS= read -r username
if [[ -z "${username//[[:space:]]/}" ]]; then
    print -u2 "The username cannot be empty."
    exit 64
fi

if security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 \
    && ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$username" >/dev/null 2>&1; then
    print -u2 "A credential for this watcher already exists under a different username."
    print -u2 "Run ./uninstall.sh --purge first if you intend to replace it."
    exit 65
fi

print "Enter the WorkSpaces password at the hidden prompt. Your input will not be shown."
security add-generic-password \
    -U \
    -s "$KEYCHAIN_SERVICE" \
    -a "$username" \
    -l "Amazon WorkSpaces reconnect credentials" \
    -T "$temporary_binary" \
    -w

is_update=false
if [[ -e "$PLIST_PATH" || -e "$BINARY" ]]; then
    is_update=true
fi

if [[ "$is_update" == true ]]; then
    print
    print "The rebuilt executable has a new macOS privacy identity."
    print "In Accessibility settings, select each existing workspaces-reconnect row."
    print "Click the − (remove) button at the bottom of the list. Turning the toggle off is not enough."
    open "$ACCESSIBILITY_URL"
    print -n "Press Return after every old workspaces-reconnect row has been removed: "
    IFS= read -r _
fi

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
move_to_trash "$BINARY"
move_to_trash "$PLIST_PATH"
move_to_trash "$STATE_PATH"
mv "$temporary_binary" "$BINARY"
temporary_binary=""

cp "$PLIST_TEMPLATE" "$temporary_plist"
plutil -replace ProgramArguments.0 -string "$BINARY" "$temporary_plist"
plutil -replace StandardOutPath -string "$LOG_PATH" "$temporary_plist"
plutil -replace StandardErrorPath -string "$LOG_PATH" "$temporary_plist"
plutil -lint "$temporary_plist" >/dev/null
mv "$temporary_plist" "$PLIST_PATH"
temporary_plist=""

run_accessibility_request
open "$ACCESSIBILITY_URL"
print
print "Turn on the newly added workspaces-reconnect entry in Accessibility settings."
print -n "Press Return after it is enabled: "
IFS= read -r _

launchctl bootstrap "$DOMAIN" "$PLIST_PATH"
"$SCRIPT_DIR/verify.sh"

print
print "Installation complete. The watcher checks WorkSpaces every 10 seconds."
