#!/bin/bash
# Installer for Keyboard Lighting — puts every piece where it belongs and
# verifies the result. Safe to re-run: every step is idempotent.
#
#   ./install.sh                       install / update, then launch the app
#   ./install.sh --check               verify an existing install, change nothing
#   ./install.sh --shortcut            add a Desktop shortcut without asking
#   ./install.sh --no-shortcut         skip it without asking
#   ./install.sh --no-launch           don't open the app at the end
#
# The flags exist so an unattended run never blocks on a prompt. Run it plainly
# and it asks about the shortcut instead.
#
# Layout it creates:
#   ~/.local/bin/{kbdrgb-gui,kbdrgb,kbdrgb-cycle}   user-side, no privileges
#   /usr/local/bin/kbdrgb-write                     root-owned sysfs writer
#   /etc/sudoers.d/kbdrgb                           NOPASSWD for that one file
#   ~/.local/share/applications/kbdrgb.desktop      app launcher
#   GNOME custom keybindings                        Super+Alt+Left/Right
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LED=/sys/class/leds/asus::kbd_backlight
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
KEYPATH=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
MEDIA=org.gnome.settings-daemon.plugins.media-keys

ok()   { printf '  \033[32m✓\033[0m %s\n'  "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n'  "$1"; }
skip() { printf '  \033[33m-\033[0m %s\n'  "$1"; }
step() { printf '\n\033[1m%s\033[0m\n'     "$1"; }

# Flags win over the prompt; the prompt only happens on a real terminal, so an
# unattended run (CI, piped, another script) can never hang waiting on input.
SHORTCUT=ask
LAUNCH=yes
for arg in "$@"; do
  case $arg in
    --shortcut)    SHORTCUT=yes ;;
    --no-shortcut) SHORTCUT=no  ;;
    --no-launch)   LAUNCH=no    ;;
    --check|"")    ;;
    *) bad "unknown option: $arg"; exit 1 ;;
  esac
done

ask() { # question -> 0 for yes. Defaults to no when there's no terminal.
  [[ -t 0 ]] || return 1
  local reply
  read -r -p "  $1 [y/N] " reply
  [[ ${reply,,} == y* ]]
}

# ---------------------------------------------------------------- preflight
# Fail loudly here rather than half-installing: the sysfs attribute is the one
# thing that cannot be worked around if the hardware/driver isn't right.
step "Checking this machine"
[[ -w $LED/brightness || -e $LED/kbd_rgb_mode ]] || {
  bad "$LED/kbd_rgb_mode missing — needs an ASUS laptop with the asus-nb-wmi driver loaded"
  exit 1
}
ok "asus-nb-wmi single-zone RGB present (max_brightness=$(cat "$LED/max_brightness"))"

missing=()
python3 -c 'import gi; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1")
from gi.repository import Gtk, Adw' 2>/dev/null || missing+=(python3-gi gir1.2-gtk-4.0 gir1.2-adw-1)
command -v notify-send >/dev/null || missing+=(libnotify-bin)
command -v ntfsfix     >/dev/null || true   # unrelated to this app; never required
if (( ${#missing[@]} )); then
  bad "missing dependencies — run this, then re-run the installer:"
  printf '\n      sudo apt install %s\n\n' "${missing[*]}"
  exit 1
fi
ok "GTK4 / libadwaita / notify-send available"

if [[ ${1:-} == --check ]]; then
  step "Verifying install (nothing will be changed)"
  for f in kbdrgb-gui kbdrgb kbdrgb-cycle; do
    [[ -x $BIN/$f ]] && ok "$BIN/$f" || bad "$BIN/$f missing"
  done
  [[ -x /usr/local/bin/kbdrgb-write ]] && ok "root helper installed" || bad "root helper missing"
  sudo -n /usr/local/bin/kbdrgb-write 0 106 119 >/dev/null 2>&1 \
    && ok "passwordless helper rule works" || bad "sudoers rule not working"
  [[ -f $APPS/kbdrgb.desktop ]] && ok "launcher installed" || bad "launcher missing"
  gsettings get $MEDIA custom-keybindings | grep -q kbdrgb \
    && ok "hotkeys bound" || bad "hotkeys not bound"
  "$BIN/kbdrgb-gui" --selftest
  exit 0
fi

# ------------------------------------------------------------- user-side bits
step "Installing user files"
mkdir -p "$BIN" "$APPS"
install -m 755 "$SRC/bin/kbdrgb-gui" "$SRC/bin/kbdrgb" "$SRC/bin/kbdrgb-cycle" "$BIN/"
ok "scripts -> $BIN"

# Exec= must be absolute and must point at the installed copy, not this source
# tree — the source may live on a drive that isn't mounted at login.
sed "s|^Exec=.*|Exec=$BIN/kbdrgb-gui|" "$SRC/share/kbdrgb.desktop" > "$APPS/kbdrgb.desktop"
update-desktop-database "$APPS" 2>/dev/null || true
ok "launcher -> $APPS/kbdrgb.desktop"

# --- optional Desktop shortcut (the app-grid entry above is installed regardless)
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
[[ $SHORTCUT == ask ]] && { ask "Also put a shortcut on your Desktop?" && SHORTCUT=yes || SHORTCUT=no; }
if [[ $SHORTCUT == yes ]]; then
  if [[ -d $DESKTOP_DIR ]]; then
    install -m 755 "$APPS/kbdrgb.desktop" "$DESKTOP_DIR/kbdrgb.desktop"
    # GNOME refuses to run a desktop file it doesn't trust — double-clicking one
    # without this just opens it in a text editor.
    gio set "$DESKTOP_DIR/kbdrgb.desktop" metadata::trusted true 2>/dev/null || true
    ok "shortcut -> $DESKTOP_DIR/kbdrgb.desktop"
  else
    skip "no Desktop directory at $DESKTOP_DIR — shortcut skipped"
  fi
else
  skip "no Desktop shortcut (add later with ./install.sh --shortcut)"
fi

# ------------------------------------------------------------- root-side bits
step "Installing root helper (sudo password needed once)"
sudo install -o root -g root -m 755 "$SRC/root/kbdrgb-write" /usr/local/bin/kbdrgb-write
ok "/usr/local/bin/kbdrgb-write"

# ! Validate BEFORE installing. A malformed sudoers file breaks sudo entirely,
# ! and you need sudo to repair it — so a syntax error here is a real lockout.
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
sed "s|@USER@|$USER|" "$SRC/root/kbdrgb.sudoers" > "$tmp"
if sudo visudo -cqf "$tmp" >/dev/null; then
  sudo install -o root -g root -m 440 "$tmp" /etc/sudoers.d/kbdrgb
  ok "/etc/sudoers.d/kbdrgb (validated with visudo)"
else
  bad "generated sudoers file failed validation — NOT installed, sudo left untouched"
  exit 1
fi

# ----------------------------------------------------------------- hotkeys
# Super+Alt+Left/Right: unbound in stock GNOME, so no clash with window
# snapping (Super+Left/Right) or workspace switching (Ctrl+Alt+Left/Right).
# Fn+arrow is deliberately NOT used — on this laptop it never reaches Linux.
step "Binding hotkeys"
bind_key() { # name command binding slug
  local path="$KEYPATH/$4/"
  python3 - "$path" <<'PY'
import ast, subprocess, sys   # literal_eval, not eval: never exec whatever gsettings hands back
path, = sys.argv[1:]
cur = subprocess.run(["gsettings", "get", "org.gnome.settings-daemon.plugins.media-keys",
                      "custom-keybindings"], capture_output=True, text=True).stdout.strip()
paths = [] if cur in ("@as []", "[]") else ast.literal_eval(cur)
if path not in paths:                       # idempotent: never duplicate an entry
    paths.append(path)
    subprocess.run(["gsettings", "set", "org.gnome.settings-daemon.plugins.media-keys",
                    "custom-keybindings", str(paths)], check=True)
PY
  local schema="$MEDIA.custom-keybinding:$path"
  gsettings set "$schema" name    "$1"
  gsettings set "$schema" command "$2"
  gsettings set "$schema" binding "$3"
  ok "$3  ->  $1"
}
if command -v gsettings >/dev/null && [[ -n ${XDG_CURRENT_DESKTOP:-} ]]; then
  bind_key "Keyboard lighting: next effect" "$BIN/kbdrgb-cycle next" '<Super><Alt>Right' kbdrgb-next
  bind_key "Keyboard lighting: prev effect" "$BIN/kbdrgb-cycle prev" '<Super><Alt>Left'  kbdrgb-prev
else
  bad "not a GNOME session — skipped hotkeys (bind $BIN/kbdrgb-cycle next/prev by hand)"
fi

# ----------------------------------------------------------------- verify
step "Verifying"
sudo -n /usr/local/bin/kbdrgb-write 0 106 119 0 0 \
  && ok "helper writes sysfs with no password prompt" \
  || { bad "helper still prompts — sudoers rule not active"; exit 1; }
"$BIN/kbdrgb-gui" --selftest

printf '\n\033[1mDone.\033[0m Find it in the app grid as "Keyboard Lighting", or run: kbdrgb-gui\n'
printf 'Effects also step with Super+Alt+Left / Super+Alt+Right.\n'
[[ ":$PATH:" == *":$BIN:"* ]] || printf '\nNote: %s is not on your PATH.\n' "$BIN"

# --- open it, so a fresh install ends with the thing you installed on screen
if [[ $LAUNCH == yes ]]; then
  if [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]]; then
    if pgrep -f "python3 $BIN/kbdrgb-gui" >/dev/null; then
      # Adw.Application is single-instance: a second start just re-presents the
      # existing window, so an already-open app is nothing to work around.
      printf '\nAlready running — bringing its window forward.\n'
    else
      printf '\nStarting Keyboard Lighting...\n'
    fi
    setsid "$BIN/kbdrgb-gui" >/dev/null 2>&1 </dev/null &
  else
    printf '\nNo display detected (headless/SSH) — not launching. Run kbdrgb-gui from the desktop.\n'
  fi
fi
