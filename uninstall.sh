#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly LABEL="com.jonasjancarik.workspaces-reconnect"
readonly KEYCHAIN_SERVICE="codex-amazon-workspaces"
readonly SUPPORT_DIR="$HOME/Library/Application Support/WorkSpacesReconnect"
readonly PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly DOMAIN="gui/$(id -u)"
readonly ACCESSIBILITY_URL="x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

purge=false
case "${1:-}" in
    "") ;;
    --purge) purge=true ;;
    *)
        print -u2 "usage: ./uninstall.sh [--purge]"
        exit 64
        ;;
esac
if (( $# > 1 )); then
    print -u2 "usage: ./uninstall.sh [--purge]"
    exit 64
fi

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

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
move_to_trash "$PLIST_PATH"
move_to_trash "$SUPPORT_DIR"

if [[ "$purge" == true ]]; then
    if security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
        print "Removed the WorkSpaces credential from Keychain."
    else
        print "No WorkSpaces credential was present in Keychain."
    fi
else
    print "The WorkSpaces credential remains in Keychain for a future reinstall."
fi

open "$ACCESSIBILITY_URL"
print "The watcher has been uninstalled."
print "Select each workspaces-reconnect row and click the − (remove) button at the bottom of the list."
print "Turning the toggle off is not enough to remove its privacy entry."
print "The cloned source directory was left untouched."
