# tailscale.zsh
#
# On Linux the vendor installer puts `tailscale` on PATH and there is nothing to do.
#
# On macOS the cask installs the GUI app, whose CLI lives inside the bundle and has no
# `binary` stanza to link it out — so `tailscale` is not a command, and `zcomp tailscale`
# was silently generating nothing (zcomp returns early unless $+commands[tailscale]).
#
# A function, not an alias: aliases do not expand when the name appears as an argument,
# which is exactly how zcomp and the completion system look a command up. The path is
# written out rather than held in a variable, because the body is evaluated at call time
# and any helper variable would have to leak into the shell to still be there.
if [[ "$OSTYPE" == darwin* ]] && (( ! $+commands[tailscale] )); then
  if [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
    tailscale() { /Applications/Tailscale.app/Contents/MacOS/Tailscale "$@" }
  fi
fi

# zcomp skips a command it cannot find, so this is a no-op until one of the above holds.
zcomp tailscale
