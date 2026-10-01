# tsm — config, flag translation, safety gates. Platform-independent.
#
# Sourced by ~/.local/bin/tsm before the platform lib. Written for bash 3.2, because
# macOS still ships it and a non-interactive context (ssh 'cmd', cron, an install hook)
# never sources the rc files that would put a newer bash on PATH. So: no associative
# arrays, no mapfile, no ${var,,}.

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

# Read scalar key $1 from the config, or empty. yq prints the string "null" for a missing
# key, which would otherwise become a literal flag value.
cfg() {
  local v
  v="$(K="$1" yq -r '.[strenv(K)] // ""' "$TSM_CONFIG" 2>/dev/null)" || return 0
  [[ "$v" == "null" ]] && v=""
  printf '%s\n' "$v"
}

# Read list key $1 as comma-separated, or empty.
cfg_list() {
  K="$1" yq -r '(.[strenv(K)] // []) | join(",")' "$TSM_CONFIG" 2>/dev/null || true
}

# Read boolean key $1. Unset is NOT the same as false: an unset key is not passed at all,
# so the caller can tell "leave it alone" from "explicitly off".
# Presence is tested with `yq -e has(...)` by exit code, and the value read separately.
# This is mikefarah's yq, not jq: it has no if/then/else/end, and ppm's own packages.sh
# uses exactly this idiom.
cfg_bool() {
  local v
  K="$1" yq -e 'has(strenv(K))' "$TSM_CONFIG" >/dev/null 2>&1 || { printf '\n'; return 0; }
  v="$(K="$1" yq -r '.[strenv(K)]' "$TSM_CONFIG" 2>/dev/null)" || v=""
  case "$v" in
    true|True|TRUE|yes|1)  printf 'true\n' ;;
    false|False|FALSE|no|0) printf 'false\n' ;;
    *) printf '\n' ;;
  esac
}

load_config() {
  [[ -f "$TSM_CONFIG" ]] || die "no config at %s\n  copy the example:  cp %s/tailscale/config.example.yml %s" \
    "$TSM_CONFIG" "${XDG_CONFIG_HOME:-$HOME/.config}" "$TSM_CONFIG"
  yq -e '.' "$TSM_CONFIG" >/dev/null 2>&1 || die "%s is not valid YAML" "$TSM_CONFIG"

  CFG_HOSTNAME="$(cfg hostname)"
  CFG_TAGS="$(cfg_list tags)"
  CFG_SSH="$(cfg_bool ssh)"
  CFG_ACCEPT_DNS="$(cfg_bool accept_dns)"
  CFG_ACCEPT_ROUTES="$(cfg_bool accept_routes)"
  CFG_ADVERTISE_ROUTES="$(cfg_list advertise_routes)"
  CFG_ADVERTISE_EXIT_NODE="$(cfg_bool advertise_exit_node)"
  CFG_EXIT_NODE="$(cfg exit_node)"
  CFG_OPERATOR="$(cfg operator)"
}

# Every unknown key is a typo that would otherwise be silently ignored — `accept-routes`
# instead of `accept_routes` is a config that looks right and does nothing.
check_unknown_keys() {
  local known=" hostname tags ssh accept_dns accept_routes advertise_routes advertise_exit_node exit_node operator "
  local key unknown=""
  for key in $(yq -r 'keys | .[]' "$TSM_CONFIG" 2>/dev/null); do
    case "$known" in *" $key "*) continue ;; esac
    unknown="$unknown $key"
  done
  [[ -z "$unknown" ]] || warn "unknown key(s) in %s:%s" "$TSM_CONFIG" "$unknown"
}

# ---------------------------------------------------------------------------
# Flag translation
# ---------------------------------------------------------------------------

# Flags shared by `up` and `set`. Booleans are always emitted explicitly rather than as
# bare switches: `tailscale up` does not persist flags between runs, so an omitted flag
# silently reverts to its default and the config would not mean what it says.
#
# Fills the global array TS_FLAGS.
build_flags() {
  TS_FLAGS=()
  [[ -n "$CFG_HOSTNAME" ]]            && TS_FLAGS[${#TS_FLAGS[@]}]="--hostname=$CFG_HOSTNAME"
  [[ -n "$CFG_SSH" ]]                 && TS_FLAGS[${#TS_FLAGS[@]}]="--ssh=$CFG_SSH"
  [[ -n "$CFG_ACCEPT_DNS" ]]          && TS_FLAGS[${#TS_FLAGS[@]}]="--accept-dns=$CFG_ACCEPT_DNS"
  [[ -n "$CFG_ACCEPT_ROUTES" ]]       && TS_FLAGS[${#TS_FLAGS[@]}]="--accept-routes=$CFG_ACCEPT_ROUTES"
  [[ -n "$CFG_ADVERTISE_EXIT_NODE" ]] && TS_FLAGS[${#TS_FLAGS[@]}]="--advertise-exit-node=$CFG_ADVERTISE_EXIT_NODE"
  [[ -n "$CFG_ADVERTISE_ROUTES" ]]    && TS_FLAGS[${#TS_FLAGS[@]}]="--advertise-routes=$CFG_ADVERTISE_ROUTES"
  [[ -n "$CFG_EXIT_NODE" ]]           && TS_FLAGS[${#TS_FLAGS[@]}]="--exit-node=$CFG_EXIT_NODE"
  # --operator= with an empty value is rejected, so it is omitted rather than cleared.
  [[ -n "$CFG_OPERATOR" ]]            && TS_FLAGS[${#TS_FLAGS[@]}]="--operator=$CFG_OPERATOR"
  return 0
}

# Join-only flags. Tags are a join-time property: `tailscale set` cannot change them.
build_join_flags() {
  build_flags
  [[ -n "$CFG_TAGS" ]] && TS_FLAGS[${#TS_FLAGS[@]}]="--advertise-tags=$CFG_TAGS"
  return 0
}

# ---------------------------------------------------------------------------
# The join credential
# ---------------------------------------------------------------------------

# An OAuth client secret (tskey-client-...) never expires and is the credential to prefer;
# a plain auth key (tskey-auth-...) is capped at 90 days by Tailscale and will strand you.
# An OAuth secret can only mint a TAGGED node, so it requires tags in the config.
classify_authkey() {
  case "$1" in
    tskey-client-*) printf 'oauth\n' ;;
    tskey-auth-*)   printf 'authkey\n' ;;
    *)              printf 'unknown\n' ;;
  esac
}

# The credential, or empty. Environment first — that is what `fnox exec` provides, and
# what an operator exporting it by hand expects to win. Non-fatal so `tsm prereqs` can
# report on it; resolve_authkey() is the fatal wrapper the join path uses.
try_authkey() {
  if [[ -n "${TS_AUTHKEY:-}" ]]; then printf '%s' "$TS_AUTHKEY"; return 0; fi
  command -v fnox >/dev/null 2>&1 || return 1
  local k
  k="$(fnox get TS_AUTHKEY 2>/dev/null || true)"
  [[ -n "$k" ]] || return 1
  printf '%s' "$k"
}

# How the key reaches tailscale. `--auth-key=<literal>` puts the secret in argv, where any
# local user can read it from ps — which is exactly what pde/op goes out of its way to
# avoid (see op/CLAUDE.md invariant 5, "the token never enters argv").
#
# Tailscale documents a file: prefix for the tailscaled config file's authKey. Whether the
# CLI flag honours it is undocumented, so it is probed rather than assumed, and the result
# is visible in `tsm info`. Override with TSM_AUTHKEY_MODE=file|argv.
authkey_mode() {
  if [[ -n "${TSM_AUTHKEY_MODE:-}" ]]; then printf '%s\n' "$TSM_AUTHKEY_MODE"; return 0; fi
  if "$TAILSCALE_BIN" up --help 2>&1 | grep -q 'file:'; then printf 'file\n'; else printf 'argv\n'; fi
}

# ---------------------------------------------------------------------------
# Not cutting off the branch you are sitting on
# ---------------------------------------------------------------------------

# SSH_CONNECTION is "client-ip client-port server-ip server-port". Empty when not over ssh.
ssh_server_ip() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  set -- $SSH_CONNECTION
  [[ -n "${3:-}" ]] || return 1
  printf '%s\n' "$3"
}

# Refuse, by default, to apply routing changes that can sever the session applying them.
#
# --exit-node sends ALL traffic through another node, including the path this ssh session
# is using. --accept-routes is subtler: if any subnet router advertises a range covering
# the address we are connected over, that traffic is pulled into the tailnet and the
# session dies. We cannot enumerate the tailnet's routes before joining it, so this is
# deliberately conservative — it asks rather than guesses.
preflight_ssh_guard() {
  local ip risky=""
  ip="$(ssh_server_ip)" || return 0          # not over ssh: nothing to protect

  [[ "$CFG_ACCEPT_ROUTES" == "true" ]] && risky="$risky accept_routes"
  [[ -n "$CFG_EXIT_NODE" ]]            && risky="$risky exit_node"
  [[ -n "$risky" ]] || return 0

  if [[ "$ASSUME_YES" == "true" ]]; then
    warn "applying%s over an ssh session to %s — if this drops, you need console access" "$risky" "$ip"
    return 0
  fi

  printf 'tsm: refusing to apply%s while connected over ssh to %s\n\n' "$risky" "$ip" >&2
  cat >&2 <<EOF
  Either of these can redirect the route your session is using, and Tailscale does not
  fall back to a less specific route — the connection simply stops.

  Safe ways forward:
    - join first without them, then enable them from a second path:
        tsm join            # with accept_routes/exit_node unset in the config
    - or, with console access to this machine standing by:
        tsm join --yes
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# The prerequisite gate
# ---------------------------------------------------------------------------

# The tailnet-side setup (tagOwners, the OAuth client, the ACL rule, the 1Password item)
# cannot be done from the host being joined, and a join missing any of it fails with a
# Tailscale-side error that does not say which piece is absent. So tsm asks once per host.
#
# The ack carries a fingerprint of the tailnet-identifying part of the config — the tags —
# so re-pointing a host at a different tailnet asks again, while editing a hostname or
# toggling ssh does not.
ack_fingerprint() {
  printf '%s' "$CFG_TAGS" | tr ',' '\n' | sort | tr '\n' ',' | cksum | awk '{print $1}'
}

ack_file() { printf '%s/prereqs-ack\n' "$TSM_CACHE"; }

ack_is_current() {
  local f want have
  f="$(ack_file)"
  [[ -f "$f" ]] || return 1
  want="$(ack_fingerprint)"
  have="$(awk -F= '$1=="fingerprint"{print $2}' "$f" 2>/dev/null)"
  [[ "$have" == "$want" ]]
}

ack_write() {
  # --dry-run promises to touch nothing, and the ack is a real side effect.
  [[ "$DRY_RUN" == "true" ]] && return 0
  mkdir -p "$TSM_CACHE"
  {
    printf '# tsm — prerequisite acknowledgement. Safe to delete; costs one prompt.\n'
    printf 'acknowledged_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'fingerprint=%s\n' "$(ack_fingerprint)"
    printf 'tags=%s\n' "$CFG_TAGS"
  } > "$(ack_file)"
}

# Returns 0 to proceed. Exits non-zero otherwise — never returns a "no".
require_prereq_ack() {
  ack_is_current && return 0

  # --yes is the standing acknowledgement, and the only thing that makes the TSM_AUTOJOIN
  # install hook usable.
  if [[ "$ASSUME_YES" == "true" ]]; then ack_write; return 0; fi

  # No tty: an install hook runs in a subshell of ppm, and `ssh host 'ppm install ...'`
  # has no tty at all. A read here would block forever on a prompt nobody can see.
  if [[ ! -t 0 ]]; then
    printf 'tsm: the tailnet prerequisites have not been acknowledged on this host,\n' >&2
    printf '     and there is no terminal to ask on.\n\n' >&2
    printf '     Review them:   tsm prereqs\n' >&2
    printf '     Then join:     tsm join --yes\n' >&2
    exit 1
  fi

  printf 'This host has not confirmed the tailnet prerequisites.\n'
  printf 'They are done once per tailnet, in the admin console — not on this machine.\n\n'
  printf 'Have you completed the tailnet prerequisites? [y/N] '
  local reply=""
  read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES|Yes) ack_write; printf '\n' ;;
    *) printf '\n'; cmd_prereqs; exit 1 ;;
  esac
}
