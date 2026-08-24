#!/bin/bash
# Undo install.sh. Restores any .bak it made, removes the scripts and the shell rc block, and
# leaves the packages alone — they were probably wanted for other reasons.
set -u
ASSUME_YES=0
for a in "$@"; do case "$a" in --yes|-y) ASSUME_YES=1 ;; esac; done

# Ask once. Reads /dev/tty when there is one so the prompt still works if the script was piped in
# (curl ... | bash), and falls back to stdin when there is not — /dev/tty is "Device not
# configured" in CI and in any non-interactive shell, and `set -u` then trips on the unset reply.
confirm() {
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  local reply=""
  printf "Continue? [y/N] "
  if [ -r /dev/tty ]; then read -r reply < /dev/tty 2>/dev/null || reply=""
  else read -r reply || reply=""; fi
  case "$reply" in y|Y|yes|YES) return 0 ;; *) echo "Cancelled. Nothing was changed."; return 1 ;; esac
}
BOLD=$'\e[1m'; OFF=$'\e[0m'
echo "${BOLD}This removes:${OFF}"
echo "  ~/.local/bin/{dev-layout,claude-banner,clip-image-path,keybytes}"
echo "  the iTerm2 \"Dev\" dynamic profile"
echo "  the marked block from your shell rc"
echo "  ~/.tmux.conf and the yazi configs — restored from .bak where one exists"
echo
echo "It does NOT uninstall tmux, yazi, starship, eza, pngpaste, iTerm2 or the font."
confirm || exit 0

for f in dev-layout claude-banner clip-image-path keybytes yazi-edit yazi-edit-run; do rm -f "$HOME/.local/bin/$f"; done
rm -f "$HOME/.config/yazi-edit/vimrc"; rmdir "$HOME/.config/yazi-edit" 2>/dev/null
rm -f "$HOME/Library/Application Support/iTerm2/DynamicProfiles/dev.json"
for f in "$HOME/.tmux.conf" "$HOME/.config/yazi/yazi.toml" "$HOME/.config/yazi/keymap.toml" "$HOME/.config/starship.toml"; do
  if [ -f "$f.bak" ]; then mv "$f.bak" "$f"; echo "  restored $f"; else rm -f "$f"; echo "  removed  $f"; fi
done
# The status line: remove the script, and unwire it from settings.json only if it is still
# pointing at ours. Someone may have replaced it with their own since.
if [ -f "$HOME/.claude/statusline-command.sh" ]; then
  rm -f "$HOME/.claude/statusline-command.sh"
  python3 - "$HOME/.claude/settings.json" <<'PYSL' 2>/dev/null
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
if p.exists():
    d = json.loads(p.read_text())
    cmd = (d.get("statusLine") or {}).get("command", "")
    if "statusline-command.sh" in cmd:
        d.pop("statusLine", None)
        p.write_text(json.dumps(d, indent=2) + "\n")
        print("  unwired statusLine from settings.json")
PYSL
  echo "  removed  ~/.claude/statusline-command.sh"
fi

# ~/.config/dev-layout/folder is KEPT on purpose: it is the one file you were expected to edit,
# and losing your chosen folder to an uninstall is a rude surprise on a re-install.

case "${SHELL##*/}" in bash) RC="$HOME/.bashrc" ;; *) RC="$HOME/.zshrc" ;; esac
python3 - "$RC" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1])
if p.exists():
    t = p.read_text()
    n = re.sub(r"\n*# >>> tmux-claude-workspace >>>.*?# <<< tmux-claude-workspace <<<\n*", "\n", t, flags=re.S)
    p.write_text(n)
    print("  cleaned", p)
PY
echo "Done. Restart your terminal."
