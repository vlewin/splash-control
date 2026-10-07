#!/usr/bin/env bash
set -euo pipefail

DEST="${1:-/tmp/splash_dashboard.png}"
TAB="${2:-}"  # optional: 1/live, 2/metrics, 3/stats, 4/logs, 5/settings, 6/info

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Bring SplashControl to front and ensure Dashboard window is open if requested
#
# No scroll-bar manipulation here, deliberately. Setting `value of scroll bar 1
# of scroll area 1 to 0.0` through System Events left the SwiftUI scroll view
# elastic-over-scrolled: the capture came back with ~55 pt of blank window above
# a card whose header was clipped off. Every tab is rebuilt from scratch when
# it is selected (`DashboardView` builds only the selected branch), so a freshly
# switched-to tab is already at the top — the reset could only ever break it.
if [ -n "$TAB" ]; then
    case "$TAB" in
        1|live|Live)         TAB_IDX=1 ;;
        2|metric*|Metric*)   TAB_IDX=2 ;;
        3|stat*|Stat*)       TAB_IDX=3 ;;
        4|log*|Log*)         TAB_IDX=4 ;;
        5|setting*|Setting*) TAB_IDX=5 ;;
        6|info|Info)          TAB_IDX=6 ;;
        *) TAB_IDX=1 ;;
    esac
    osascript << APPLESCRIPT >/dev/null 2>&1
tell application "System Events"
    if exists (process "SplashControl") then
        tell process "SplashControl"
            set frontmost to true
            if not (exists window "Splash") then
                set mb to menu bar (count of menu bars)
                click menu item "Open Dashboard" of menu 1 of menu bar item 1 of mb
            end if
            if exists window "Splash" then
                tell window "Splash"
                    if exists (radio button $TAB_IDX of radio group 1 of group 1 of toolbar 1) then
                        click radio button $TAB_IDX of radio group 1 of group 1 of toolbar 1
                    else if exists (radio button $TAB_IDX of radio group 1 of group 1) then
                        click radio button $TAB_IDX of radio group 1 of group 1
                    end if
                end tell
            end if
        end tell
    end if
end tell
APPLESCRIPT
    # The window now animates its height over 0.22 s on every tab switch, and
    # `screencapture` fires well inside that. Without this settle the capture
    # lands mid-animation and the PNG shows a height no tab is configured for.
    sleep 0.4
fi

# 2. Get Window ID
if [ ! -x "$DIR/find-window-id" ] && [ -f "$DIR/find-window-id.swift" ]; then
    swiftc -O "$DIR/find-window-id.swift" -o "$DIR/find-window-id" 2>/dev/null || true
fi
if [ -x "$DIR/find-window-id" ]; then
    WID="$("$DIR/find-window-id" "Splash Control" Splash 2>/dev/null || "$DIR/find-window-id" Splash Splash 2>/dev/null || true)"
fi
if [ -z "${WID:-}" ]; then
    WID=$(swift -e '
import CoreGraphics
if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let name = w[kCGWindowName as String] as? String ?? ""
        let wid = w[kCGWindowNumber as String] as? Int ?? 0
        if (owner == "Splash Control" || owner == "Splash" || owner == "SplashControl") && (name == "Splash" || name == "Splash Control") {
            print(wid)
            break
        }
    }
}
')
fi

if [ -z "$WID" ]; then
    echo "Error: Splash dashboard window not found" >&2
    exit 1
fi

# 3. Capture cleanly
screencapture -l "$WID" -o "$DEST"
echo "Captured Splash window (ID $WID) to $DEST"
