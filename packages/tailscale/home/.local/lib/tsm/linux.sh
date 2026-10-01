# tsm — Linux platform lib.
#
# Sourced by ~/.local/bin/tsm on Linux. Every platform lib implements the same four
# functions; see darwin.sh for the contract.

# The tailscale CLI. On Linux the vendor installer puts it on PATH.
find_tailscale_bin() {
  local c
  for c in "${TAILSCALE_BIN:-}" /usr/bin/tailscale /usr/local/bin/tailscale; do
    [[ -n "$c" && -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  command -v tailscale 2>/dev/null && return 0
  return 1
}

# Is the daemon running and able to answer? Distinguished from "installed" because a
# stopped tailscaled looks exactly like a broken install from the CLI's error message.
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
  if command -v systemctl >/dev/null 2>&1; then
    printf 'start it with:  sudo systemctl enable --now tailscaled\n'
  else
    printf 'no systemd here; start it with:  sudo tailscaled --tun=userspace-networking &\n'
  fi
}

# True when a state-changing call has to go through sudo. Root needs none; neither does
# a user the daemon already accepts as its operator (`tailscale set --operator=<user>`),
# which is what `debug prefs` succeeding proves.
#
# Callers care because sudo closes every fd >= 3 before exec, so it rules out handing the
# join key over a pipe — see run_up().
ts_needs_sudo() {
  [[ "$(id -u)" == "0" ]] && return 1
  "$TAILSCALE_BIN" debug prefs >/dev/null 2>&1 && return 1
  command -v sudo >/dev/null 2>&1
}

# `tailscale up` needs root on Linux unless an operator was set.
ts_privileged() {
  if ts_needs_sudo; then
    sudo -- "$TAILSCALE_BIN" "$@"
  else
    "$TAILSCALE_BIN" "$@"
  fi
}
