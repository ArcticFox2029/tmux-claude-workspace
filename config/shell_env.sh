# Sourced from your shell rc by install.sh, inside a marked block.
#
# It lives here rather than being pasted into ~/.zshrc so that updating this repo updates your
# shell too, and so an uninstall is one block to remove rather than a diff to reconstruct.

# starship, only where it belongs. A prompt set unconditionally in the rc follows you into every
# terminal you own — including the plain Terminal.app and the one embedded in your editor, which is
# a surprising thing to have happen from installing a tmux layout.
if command -v starship >/dev/null 2>&1 \
   && { [ "${TERM_PROGRAM:-}" = "iTerm.app" ] || [ -n "${TMUX:-}" ]; }; then
  eval "$(starship init "${SHELL##*/}")"
fi

if command -v eza >/dev/null 2>&1; then
  alias ls='eza --icons --group-directories-first'
  alias ll='eza -l --icons --group-directories-first --git --time-style=long-iso'
  alias lt='eza --tree --level=2 --icons --group-directories-first'
fi

# yazi's own wrapper: `y` leaves you in whatever directory you were browsing when you quit, which
# is the reason to use a file browser in a terminal at all.
if command -v yazi >/dev/null 2>&1; then
  y() {
    local tmp cwd
    tmp="$(mktemp -t yazi-cwd.XXXXXX)"
    yazi "$@" --cwd-file="$tmp"
    cwd="$(command cat -- "$tmp")"
    [ -n "$cwd" ] && [ "$cwd" != "$PWD" ] && builtin cd -- "$cwd"
    rm -f -- "$tmp"
  }
fi

# cimg: put the clipboard image (or the newest screenshot file) somewhere permanent and print the
# path — then leave that path on the clipboard as TEXT, which survives being pasted anywhere.
#
# Worth knowing what this is NOT for. Claude Code's own ctrl+v already attaches a clipboard image,
# and inside tmux too — the image never travels through tmux, the program reads the macOS pasteboard
# directly. cimg is for the other case: an image that has to be opened more than once, handed to a
# different tool, or kept. A path can be reused; a paste is consumed.
cimg() {
    local finder="$HOME/.local/bin/clip-image-path" out bytes dims
    if [ ! -x "$finder" ]; then
        echo "cimg: clip-image-path not found — re-run install.sh" >&2; return 1
    fi
    out=$("$finder") || return 1
    if [ "$#" -gt 0 ]; then
        local named="${CLIPIMG_DIR:-$HOME/.local/share/clipboard-images}/${1%.png}.png"
        [ "$out" != "$named" ] && cp -- "$out" "$named" && out="$named"
    fi
    bytes=$(wc -c < "$out" | tr -d ' ')
    dims=$(/usr/bin/sips -g pixelWidth -g pixelHeight "$out" 2>/dev/null \
           | awk '/pixel/{printf "%s", (n++ ? "x" : "")$2}')
    echo "$out"
    echo "  ${dims:-?} · $((bytes / 1024)) KB" >&2
    printf '%s' "$out" | pbcopy 2>/dev/null
}
