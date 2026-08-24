#!/bin/bash
# One command to set the whole thing up. Reads what is missing, tells you, asks once, then does it.
#
#   bash install.sh              install, asking before anything is changed
#   bash install.sh --dry-run    print the plan and change nothing
#   bash install.sh --yes        skip the prompt (for scripted setups)
#
# macOS only. It depends on Homebrew, iTerm2 dynamic profiles and the macOS pasteboard, none of
# which have a Linux equivalent here — see the README.
set -u

DRY=0; ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

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

SRC="$(cd "$(dirname "$0")" && pwd)/config"
BOLD=$'\e[1m'; DIM=$'\e[2m'; GRN=$'\e[32m'; YEL=$'\e[33m'; OFF=$'\e[0m'

[ "$(uname -s)" = "Darwin" ] || { echo "This installer is macOS only."; exit 1; }

# ── What is missing ────────────────────────────────────────────────────────────────────────────
# Required: without these the workspace does not open at all.
# Optional: each adds one feature and is skipped cleanly if absent.
REQ_BREW=(tmux)
# vim ships with macOS and already has +clipboard and +mouse, so it is not installed here.
OPT_BREW=(yazi starship eza pngpaste)
CASKS=(iterm2 font-jetbrains-mono-nerd-font)

# 🐛 macOS ships bash 3.2, where "${arr[@]}" on an EMPTY array is an unbound-variable error under
# `set -u` — so the installer died at the first check on a machine that had everything already.
# ${arr[@]+"${arr[@]}"} expands to nothing when the array is empty instead of erroring. Found by
# running the installer into a throwaway HOME rather than by reading it.
missing_req=(); missing_opt=(); missing_cask=()
for p in ${REQ_BREW[@]+"${REQ_BREW[@]}"}; do command -v "$p" >/dev/null 2>&1 || missing_req+=("$p"); done
for p in ${OPT_BREW[@]+"${OPT_BREW[@]}"}; do command -v "$p" >/dev/null 2>&1 || missing_opt+=("$p"); done
[ -d "/Applications/iTerm.app" ] || missing_cask+=("iterm2")
if ! ls ~/Library/Fonts/JetBrainsMonoNerd* >/dev/null 2>&1 \
   && ! ls /Library/Fonts/JetBrainsMonoNerd* >/dev/null 2>&1; then
  missing_cask+=("font-jetbrains-mono-nerd-font")
fi

have_brew=1; command -v brew >/dev/null 2>&1 || have_brew=0

# ── The plan, printed before anything happens ──────────────────────────────────────────────────
echo
echo "${BOLD}This will install:${OFF}"
echo "  config files"
echo "    ~/.tmux.conf                                  tmux layout and key bindings"
echo "    ~/.config/yazi/{yazi,keymap}.toml             file browser: two columns, mouse on"
echo "    ~/.config/starship.toml                       prompt (only if starship is installed)"
echo "    ~/.local/bin/{dev-layout,claude-banner,...}   the workspace launcher and helpers
    ~/.config/yazi-edit/vimrc                     editor config for `e` (never touches ~/.vimrc)"
echo "    iTerm2 dynamic profile \"Dev\"                  window size, font, key mappings"
echo "    a marker block appended to your shell rc       PATH and locale
    ~/.claude/statusline-command.sh                status line (only if Claude Code is installed)"
echo

if [ ${#missing_req[@]} -gt 0 ] || [ ${#missing_opt[@]} -gt 0 ] || [ ${#missing_cask[@]} -gt 0 ]; then
  echo "${BOLD}And install what is missing:${OFF}"
  [ ${#missing_req[@]}  -gt 0 ] && echo "  ${YEL}required${OFF}  ${missing_req[*]-}"
  [ ${#missing_opt[@]}  -gt 0 ] && echo "  optional  ${missing_opt[*]-}   ${DIM}(each one is a feature; skipped if you decline)${OFF}"
  [ ${#missing_cask[@]} -gt 0 ] && echo "  casks     ${missing_cask[*]-}"
  [ "$have_brew" = "0" ] && echo "  ${YEL}Homebrew is not installed — install it first: https://brew.sh${OFF}"
  echo
else
  echo "${GRN}Everything it depends on is already installed.${OFF}"
  echo
fi

echo "${BOLD}It will NOT:${OFF}"
echo "  overwrite an existing ~/.tmux.conf or yazi config without saving a .bak first"
echo "  touch your shell rc more than once (the block is marked and replaced in place)"
echo "  change your default iTerm2 profile"
echo

if [ "$DRY" = "1" ]; then echo "${DIM}--dry-run: nothing was changed.${OFF}"; exit 0; fi

confirm || exit 0

# ── Packages ───────────────────────────────────────────────────────────────────────────────────
if [ "$have_brew" = "1" ]; then
  for p in ${missing_req[@]+"${missing_req[@]}"} ${missing_opt[@]+"${missing_opt[@]}"}; do
    echo "  installing $p ..."; brew install "$p" >/dev/null 2>&1 \
      && echo "    ${GRN}ok${OFF}" || echo "    ${YEL}failed — carrying on${OFF}"
  done
  for c in ${missing_cask[@]+"${missing_cask[@]}"}; do
    echo "  installing $c ..."; brew install --cask "$c" >/dev/null 2>&1 \
      && echo "    ${GRN}ok${OFF}" || echo "    ${YEL}failed — carrying on${OFF}"
  done
elif [ ${#missing_req[@]} -gt 0 ]; then
  echo "${YEL}tmux is required and Homebrew is not available. Install tmux, then re-run.${OFF}"
  exit 1
fi

# Homebrew-installed fonts arrive quarantined, and macOS silently refuses to register a quarantined
# font — icons then render as "?" with no error anywhere. Clearing the flag is not enough on its
# own; fontd has to be restarted before it looks again.
for d in ~/Library/Fonts /Library/Fonts; do
  if ls "$d"/JetBrainsMonoNerd* >/dev/null 2>&1; then
    xattr -d com.apple.quarantine "$d"/JetBrainsMonoNerd* 2>/dev/null && killall fontd 2>/dev/null
  fi
done

# ── Config files ───────────────────────────────────────────────────────────────────────────────
backup() { [ -f "$1" ] && [ ! -f "$1.bak" ] && cp "$1" "$1.bak" && echo "    saved $1.bak"; }

mkdir -p "$HOME/.local/bin" "$HOME/.config/yazi" "$HOME/.config/dev-layout" \
         "$HOME/Library/Application Support/iTerm2/DynamicProfiles"

for f in dev-layout claude-banner clip-image-path keybytes yazi-edit yazi-edit-run; do
  install -m 755 "$SRC/$f" "$HOME/.local/bin/$f"
done
echo "  ${GRN}ok${OFF}  scripts -> ~/.local/bin"

backup "$HOME/.tmux.conf";                 install -m 644 "$SRC/tmux.conf"        "$HOME/.tmux.conf"
backup "$HOME/.config/yazi/yazi.toml";     install -m 644 "$SRC/yazi.toml"        "$HOME/.config/yazi/yazi.toml"
backup "$HOME/.config/yazi/keymap.toml";   install -m 644 "$SRC/yazi-keymap.toml" "$HOME/.config/yazi/keymap.toml"
backup "$HOME/.config/starship.toml";      install -m 644 "$SRC/starship.toml"    "$HOME/.config/starship.toml"
# The editor config for `e`. Loaded with `vim -u`, so a personal ~/.vimrc is never touched.
mkdir -p "$HOME/.config/yazi-edit"
install -m 644 "$SRC/editor/vimrc" "$HOME/.config/yazi-edit/vimrc"
echo "  ${GRN}ok${OFF}  configs"

# The Claude Code status line, if Claude Code is installed. Opt-in: it is wired into
# ~/.claude/settings.json, which is a file you may already have opinions about.
if [ -d "$HOME/.claude" ]; then
  install -m 755 "$SRC/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
  python3 - "$HOME/.claude/settings.json" <<'PYSL'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text()) if p.exists() else {}
if "statusLine" not in d:
    d["statusLine"] = {"type": "command", "command": 'bash "$HOME/.claude/statusline-command.sh"'}
    p.write_text(json.dumps(d, indent=2) + "\n")
    print("  wired into settings.json")
else:
    print("  settings.json already has a statusLine — left alone")
PYSL
  echo "  ${GRN}ok${OFF}  Claude Code status line"
fi

# The profile is GENERATED, not copied: it carries an absolute path to dev-layout, and copying it
# would hardcode whoever built it into everyone else's machine.
sed "s|__HOME__|$HOME|g" "$SRC/iterm-dev-profile.json" \
  > "$HOME/Library/Application Support/iTerm2/DynamicProfiles/dev.json"
echo "  ${GRN}ok${OFF}  iTerm2 profile \"Dev\" (written for this machine's home directory)"

# The folder the workspace opens in. Written only if absent — it is the one file you are expected
# to edit, and re-running the installer must not reset your choice.
if [ ! -f "$HOME/.config/dev-layout/folder" ]; then
  printf '%s\n' "$HOME" > "$HOME/.config/dev-layout/folder"
  echo "  ${GRN}ok${OFF}  default folder set to \$HOME — edit ~/.config/dev-layout/folder to change it"
else
  echo "  ${DIM}kept${OFF} ~/.config/dev-layout/folder"
fi

# ── Shell rc ───────────────────────────────────────────────────────────────────────────────────
# In a marked block so re-running replaces it rather than appending a second copy.
case "${SHELL##*/}" in bash) RC="$HOME/.bashrc" ;; *) RC="$HOME/.zshrc" ;; esac
BEGIN="# >>> tmux-claude-workspace >>>"
END="# <<< tmux-claude-workspace <<<"
touch "$RC"
python3 - "$RC" "$BEGIN" "$END" "$SRC" <<'PY'
import sys, pathlib, re
rc, begin, end, src = sys.argv[1:5]
block = f"""{begin}
export PATH="$HOME/.local/bin:$PATH"
# macOS DOES set LANG - to C.UTF-8, the minimal locale, which miscounts combining characters.
# So this is set, not defaulted: ${{LANG:-...}} would never fire.
export LANG=en_US.UTF-8
export LC_CTYPE=en_US.UTF-8
[ -f "{src}/shell_env.sh" ] && source "{src}/shell_env.sh"
{end}"""
p = pathlib.Path(rc); text = p.read_text()
pat = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.S)
p.write_text(pat.sub(block, text) if pat.search(text) else text.rstrip("\n") + "\n\n" + block + "\n")
PY
echo "  ${GRN}ok${OFF}  $RC (marked block, replaced in place)"

echo
echo "${BOLD}Done.${OFF}"
echo "  1. Restart iTerm2 so it picks up the \"Dev\" profile"
echo "  2. Open a window with that profile"
echo "  3. The right pane is a plain shell — run whatever you like in it"
echo
echo "${DIM}Uninstall: bash uninstall.sh${OFF}"
