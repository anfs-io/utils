# utils/tailscale — Tailscale client plus `tsm`, the tailnet join manager
#
# Linux keeps the vendor installer: it adds Tailscale's own repo and signing key and sets
# up the tailscaled systemd service, none of which ppm's brew/cask/system vocabulary can
# express. macOS gets the cask, declared in package.yml.

TSM_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/tailscale/config.yml"

pre_install() {
  local cyan='\033[0;36m' nc='\033[0m'
  echo -e "${cyan}"
  cat << "EOF"
 _____ ____  __  __
|_   _/ ___||  \/  |
  | | \___ \| |\/| |
  | |  ___) | |  | |
  |_| |____/|_|  |_|

EOF
  echo -e "${cyan}Tailscale Manager${nc}"
}

# Gate on the binary, not on the service.
#
# The old check was `systemctl is-active --quiet tailscaled`, which re-ran the vendor
# installer every time the daemon merely happened to be stopped — a reinstall to fix a
# stopped service. Installing and enabling are separate concerns, so they are separate
# steps: install only when the binary is absent, then always make sure the unit is up.
install_linux() {
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh || {
      ppm_fail "the Tailscale vendor installer failed; see https://tailscale.com/kb/1031/install-linux"
      return
    }
  fi

  # A container has no systemd; that is not a failure, it just means no unit to enable.
  command -v systemctl >/dev/null 2>&1 || {
    user_message "No systemd here, so tailscaled was not enabled.\nStart it by hand: sudo tailscaled --tun=userspace-networking &"
    return 0
  }

  systemctl is-enabled --quiet tailscaled 2>/dev/null && systemctl is-active --quiet tailscaled && return 0

  _system_sudo "enable and start tailscaled" \
    "tailscaled is installed but not running. Start it with:\n  sudo systemctl enable --now tailscaled" || return 0
  sudo -n systemctl enable --now tailscaled 2>/dev/null \
    || user_message "Could not enable tailscaled. Run: sudo systemctl enable --now tailscaled"
}

# Joining is opt-in per machine. The signal is TSM_AUTOJOIN in ~/.config/ppm/ppm.local.conf
# (uncommitted, machine-local) or ppm.conf; ppm sources every *.conf before dispatch and
# hooks run in a subshell of that process, so the value is visible here without an export.
#
# Conf vars are NOT exported, so tsm — a child process — cannot see them. Anything it needs
# is passed explicitly.
post_install() {
  if [[ ! -f "$TSM_CONFIG" ]]; then
    user_message "No tailnet config at $TSM_CONFIG — this host will not join.\nCopy the example to start:\n  cp ~/.config/tailscale/config.example.yml $TSM_CONFIG\nThen: tsm prereqs && tsm join"
    return 0
  fi

  if [[ -z "${TSM_AUTOJOIN:-}" ]]; then
    user_message "Config found at $TSM_CONFIG. Join with:\n  tsm join\nTo join automatically on every install, add to ~/.config/ppm/ppm.local.conf:\n  TSM_AUTOJOIN=true"
    return 0
  fi

  # -y here, not interactivity: an install hook has no reliable tty, and TSM_AUTOJOIN is
  # itself the operator's standing acknowledgement. tsm join is idempotent, so a second
  # install run reconciles rather than re-authenticating.
  "$HOME/.local/bin/tsm" join --yes || ppm_fail "tsm join failed; run it by hand to see why"
}

post_remove() {
  user_message "tailscaled was left installed and this node is still on the tailnet.\nTo leave: sudo tailscale logout && sudo systemctl disable --now tailscaled\nYour config in ~/.config/tailscale/ was left in place."
}
