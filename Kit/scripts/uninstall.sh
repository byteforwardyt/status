#!/bin/sh

set -u

HELPER_LABEL="app.status.Status.SMC.Helper"
AGENT_LABEL="app.status.Status"

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    HOME=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')
fi

run_as_user() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" "$@"
    else
        "$@"
    fi
}

echo "Uninstalling Status..."

run_as_user osascript -e 'quit app "Status"' >/dev/null 2>&1 || true

echo "Removing the launch agent..."
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    GUI_UID=$(id -u "$SUDO_USER")
else
    GUI_UID=$(id -u)
fi
run_as_user launchctl bootout "gui/$GUI_UID/$AGENT_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

echo "Removing the SMC helper (administrator privileges are required)..."
sudo launchctl bootout "system/$HELPER_LABEL" 2>/dev/null || true
sudo launchctl unload "/Library/LaunchDaemons/$HELPER_LABEL.plist" 2>/dev/null || true
sudo rm -f "/Library/LaunchDaemons/$HELPER_LABEL.plist"
sudo rm -f "/Library/PrivilegedHelperTools/$HELPER_LABEL"

for app in "/Applications/Status.app" "$HOME/Applications/Status.app"; do
    if [ -d "$app" ]; then
        echo "Removing $app..."
        sudo rm -rf "$app"
    fi
done

echo "Removing application data and preferences..."
rm -rf "$HOME/Library/Application Support/Status"
rm -rf "$HOME/Library/Containers/app.status.Status.Widgets"
rm -rf "$HOME/Library/Group Containers/"*.app.status.Status.widgets
run_as_user defaults delete app.status.Status >/dev/null 2>&1 || true
run_as_user defaults delete app.status.Status.Widgets >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/app.status.Status.plist"
rm -f "$HOME/Library/Preferences/app.status.Status.Widgets.plist"

echo "Status has been uninstalled."
echo "If fan speeds were controlled manually, they will return to automatic control after a reboot."
