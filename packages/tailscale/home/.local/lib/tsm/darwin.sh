# tsm — macOS platform lib.
#
# Sourced by ~/.local/bin/tsm on macOS. The contract every platform lib implements:
#
#   find_tailscale_bin   absolute path to the tailscale CLI, or non-zero
#   daemon_ready         0 when the daemon can answer (logged out still counts)
#   daemon_hint          one line telling the user how to start it
#   ts_privileged ARGS   run the CLI with whatever privilege the platform needs
#
# macOS differs from Linux in two ways that matter here. The cask installs the GUI app
# and has no `binary` stanza, so nothing lands on PATH and the CLI has to be found inside
# the bundle by absolute path — the same problem utils/rpi-imager has with Imager. And
# the app runs its own daemon under the logged-in user, so no sudo is involved.

find_tailscale_bin() {
  local c
  for c in "${TAILSCALE_BIN:-}" \
           "/Applications/Tailscale.app/Contents/MacOS/Tailscale" \
           "/Applications/Tailscale.app/Contents/MacOS/tailscale" \
           /usr/local/bin/tailscale \
           /opt/homebrew/bin/tailscale; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  command -v tailscale 2>/dev/null && return 0
  return 1
}

# `status` exits non-zero when logged out, which is still a live daemon we can talk to.
# The output is captured rather than piped: under `set -o pipefail` a pipeline takes the
# failing exit of tailscale even when grep matches, which would report a perfectly healthy
# logged-out daemon as dead — the exact state every first join starts from.
daemon_ready() {
  local out
  "$TAILSCALE_BIN" status >/dev/null 2>&1 && return 0
  out="$("$TAILSCALE_BIN" status 2>&1 || true)"
  case "$out" in *[Ll]ogged\ out*) return 0 ;; esac
  return 1
}

daemon_hint() {
  printf 'open the Tailscale app once so its daemon starts:  open -a Tailscale\n'
}

# The macOS app owns its daemon and runs it as the logged-in user, so nothing here needs
# sudo — which also means the fd-based key handoff in run_up() is usable.
ts_needs_sudo() { return 1; }

ts_privileged() { "$TAILSCALE_BIN" "$@"; }
