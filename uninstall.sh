#!/bin/bash
# Removes everything install.sh created — including the sudoers rule and the
# GNOME hotkeys, which are the two pieces a plain `rm` would leave behind.
# Leaves your saved colour in ~/.local/state/kbdrgb unless you pass --purge.
set -euo pipefail

BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
KEYPATH=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
MEDIA=org.gnome.settings-daemon.plugins.media-keys
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/kbdrgb"

ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }

# Close it first, or the window lingers with its scripts deleted underneath it.
pkill -f "python3 $BIN/kbdrgb-gui" 2>/dev/null && ok "running app closed" || true

rm -f "$BIN/kbdrgb-gui" "$BIN/kbdrgb" "$BIN/kbdrgb-cycle" "$APPS/kbdrgb.desktop"
update-desktop-database "$APPS" 2>/dev/null || true
ok "user scripts and launcher removed"

DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
rm -f "$DESKTOP_DIR/kbdrgb.desktop"
ok "Desktop shortcut removed (if there was one)"

# Drop the hotkey entries out of the list, then reset each key's own schema.
for slug in kbdrgb-next kbdrgb-prev; do
  python3 - "$KEYPATH/$slug/" <<'PY'
import ast, subprocess, sys
path, = sys.argv[1:]
S = "org.gnome.settings-daemon.plugins.media-keys"
cur = subprocess.run(["gsettings", "get", S, "custom-keybindings"],
                     capture_output=True, text=True).stdout.strip()
paths = [] if cur in ("@as []", "[]") else ast.literal_eval(cur)
if path in paths:
    paths.remove(path)
    subprocess.run(["gsettings", "set", S, "custom-keybindings", str(paths)], check=True)
PY
  for k in name command binding; do
    gsettings reset "$MEDIA.custom-keybinding:$KEYPATH/$slug/" "$k" 2>/dev/null || true
  done
done
ok "hotkeys unbound"

echo "Removing root helper and sudoers rule (sudo password needed)"
sudo rm -f /usr/local/bin/kbdrgb-write /etc/sudoers.d/kbdrgb
ok "root helper and sudoers rule removed"

if [[ ${1:-} == --purge ]]; then
  rm -rf "$STATE"
  ok "saved colour/effect state removed"
else
  echo "  (kept $STATE — pass --purge to delete it)"
fi

printf '\nDone. The keyboard keeps whatever colour was last set until reboot.\n'
