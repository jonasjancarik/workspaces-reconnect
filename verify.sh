#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly LABEL="com.jonasjancarik.workspaces-reconnect"
readonly KEYCHAIN_SERVICE="codex-amazon-workspaces"
readonly SUPPORT_DIR="$HOME/Library/Application Support/WorkSpacesReconnect"
readonly BINARY="$SUPPORT_DIR/bin/workspaces-reconnect"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly DOMAIN="gui/$(id -u)"

if (( $# != 0 )); then
    print -u2 "usage: ./verify.sh"
    exit 64
fi

if [[ ! -x "$BINARY" || ! -f "$PLIST_PATH" ]]; then
    print -u2 "The watcher is not installed. Run ./install.sh first."
    exit 66
fi

launch_agent_arguments_are_valid() {
    local plist_path="$1"
    local expected_binary="$2"

    [[ "$(plutil -extract ProgramArguments.0 raw "$plist_path")" == "$expected_binary" ]] \
        && [[ "$(plutil -extract ProgramArguments.1 raw "$plist_path")" == "check" ]] \
        && ! plutil -extract ProgramArguments.2 raw "$plist_path" >/dev/null 2>&1
}

run_once() {
    local command_name="$1"
    local marker="$2"
    local job_label="$LABEL.verify.$command_name.$$"
    local output_file
    output_file="$(mktemp "${TMPDIR:-/tmp}/workspaces-reconnect-verify.XXXXXX")"

    launchctl submit \
        -l "$job_label" \
        -o "$output_file" \
        -e "$output_file" \
        -- "$BINARY" "$command_name"

    for _ in {1..100}; do
        grep -q "$marker" "$output_file" 2>/dev/null && break
        sleep 0.1
    done

    launchctl remove "$job_label" >/dev/null 2>&1 || true
    REPLY="$(<"$output_file")"
    /bin/rm -f "$output_file"
}

if ! launch_agent_arguments_are_valid "$PLIST_PATH" "$BINARY"; then
    print -u2 "LaunchAgent verification failed:"
    print -u2 "Expected exactly: $BINARY check"
    print -u2 "Re-run ./install.sh to repair the scheduled command."
    exit 78
fi

if ! security find-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    print -u2 "The WorkSpaces credential is missing from Keychain."
    exit 67
fi

run_once diagnose '^classification='
diagnostic="$REPLY"
if [[ "$diagnostic" != *$'trusted=true'* ]]; then
    print -u2 "Accessibility verification failed in the launchd context:"
    print -u2 -- "$diagnostic"
    print -u2 "Remove and re-add workspaces-reconnect in System Settings > Privacy & Security > Accessibility."
    exit 77
fi

classification="${diagnostic#*classification=}"
classification="${classification%%$'\n'*}"

run_once credentials-check '^credentials='
credential_result="$REPLY"
if [[ "$credential_result" != *$'credentials=available'* ]]; then
    print -u2 "Keychain verification failed in the launchd context:"
    print -u2 -- "$credential_result"
    exit 77
fi

launchctl print "$DOMAIN/$LABEL" >/dev/null
interval="$(plutil -extract StartInterval raw "$PLIST_PATH")"

print "Watcher verification passed"
print "  Accessibility: trusted"
print "  Credentials: available"
print "  Screen: $classification"
print "  LaunchAgent: loaded (${interval}-second interval)"
