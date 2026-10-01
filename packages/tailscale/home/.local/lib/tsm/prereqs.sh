# tsm prereqs — the manual, tailnet-side setup, plus the parts we can check from here.
#
# Split in two deliberately. The checklist is things only you can do, in the admin
# console, once per tailnet. The checks below are the three mistakes that actually recur,
# each of which otherwise surfaces as a Tailscale-side error that does not name the cause.

cmd_prereqs() {
  local bold='' dim='' nc=''
  if [[ -t 1 ]]; then bold=$'\033[1m'; dim=$'\033[2m'; nc=$'\033[0m'; fi

  cat <<EOF
${bold}Tailnet prerequisites${nc}
Done once per tailnet, in the Tailscale admin console. None of it can be done from
this machine, which is why tsm asks rather than checks.

${bold}1. Declare the tag in the tailnet policy file${nc}
   Access controls -> Edit file. A tag that is not listed here is rejected at join
   time, and an OAuth client can only ever mint a tagged node.

     "tagOwners": {
       "tag:server": ["autogroup:admin"]
     }

${bold}2. Create an OAuth client${nc}
   Settings -> OAuth clients -> Generate. Scope ${bold}auth_keys${nc} (write), and select
   the same tag. Copy the secret — it is shown once.

   ${dim}Why not a plain auth key: Tailscale caps auth keys at 90 days and offers no
   non-expiring option, so a key parked in 1Password breaks onboarding four times a
   year. An OAuth client does not expire, and nodes it creates are tagged, which
   disables their key expiry too.${nc}

${bold}3. Store the secret in 1Password${nc}
   In a vault your service account can read, then reference it from the fnox.toml
   beside your config:

     TS_AUTHKEY = { provider = "onepass", value = "op://<vault>/tailscale-oauth/credential", env = "exec" }

   ${dim}provider must be named explicitly — a bare value is stored verbatim and never
   reaches 1Password. See pde/op's README.${nc}

$(_prereq_ssh_acl_section "$bold" "$dim" "$nc")

${bold}Local checks${nc}
$(_prereq_checks)

EOF
}

_prereq_ssh_acl_section() {
  local bold="$1" dim="$2" nc="$3"
  [[ "$(cfg_bool ssh 2>/dev/null)" == "true" ]] || return 0
  cat <<EOF
${bold}4. Grant SSH access to the tag${nc}
   Your config sets ${bold}ssh: true${nc}, which runs Tailscale's SSH server on this node.
   Without a matching ACL rule that is a door nobody holds the key to:

     {"action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["tag:server"],
      "users":  ["root", "$(id -un)"]}

   ${dim}Test it from another node before you rely on it — a wrong rule locks you out of
   a remote host.${nc}

EOF
}

# Only things that are genuinely knowable without a tailnet. Anything requiring the
# Tailscale API would need the credential we are trying to validate.
_prereq_checks() {
  local ok=$'\033[0;32m'"ok"$'\033[0m' bad=$'\033[0;31m'"--"$'\033[0m'
  if [[ ! -t 1 ]]; then ok="ok"; bad="--"; fi

  # 1. config present and parses
  if [[ ! -f "$TSM_CONFIG" ]]; then
    printf '  %s  no config at %s\n' "$bad" "$TSM_CONFIG"
    printf '      cp %s/tailscale/config.example.yml %s\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$TSM_CONFIG"
    return 0
  fi
  if ! yq -e '.' "$TSM_CONFIG" >/dev/null 2>&1; then
    printf '  %s  %s is not valid YAML\n' "$bad" "$TSM_CONFIG"
    return 0
  fi
  printf '  %s  config parses (%s)\n' "$ok" "$TSM_CONFIG"

  # 2. the credential resolves, and matches the tagging the config asks for
  local key="" kind=""
  if ! command -v fnox >/dev/null 2>&1 && [[ -z "${TS_AUTHKEY:-}" ]]; then
    printf '  %s  fnox is not installed; export TS_AUTHKEY by hand before joining\n' "$bad"
  elif key="$(try_authkey)" && [[ -n "$key" ]]; then
    kind="$(classify_authkey "$key")"
    case "$kind" in
      oauth)   printf '  %s  TS_AUTHKEY resolves (OAuth client secret — does not expire)\n' "$ok" ;;
      authkey) printf '  %s  TS_AUTHKEY resolves (plain auth key — expires within 90 days)\n' "$ok" ;;
      *)       printf '  %s  TS_AUTHKEY resolves but is not a recognised Tailscale key\n' "$bad" ;;
    esac
  else
    printf '  %s  TS_AUTHKEY is unset and fnox cannot resolve it\n' "$bad"
    printf '      check:  fnox config-files && fnox list\n'
    printf '      on a remote host the 1Password service account token must be\n'
    printf '      forwarded: ssh from a directory whose fnox.toml declares it\n'
  fi

  # 3. the tagging/credential combination is coherent
  local tags; tags="$(cfg_list tags)"
  if [[ "$kind" == "oauth" && -z "$tags" ]]; then
    printf '  %s  an OAuth secret can only create a TAGGED node, but tags is empty\n' "$bad"
    printf '      add a tag to %s, or use a plain auth key\n' "$TSM_CONFIG"
  elif [[ -n "$tags" ]]; then
    printf '  %s  tags declared (%s) — must exist in tagOwners, step 1 above\n' "$ok" "$tags"
  else
    printf '  %s  no tags: this node will be owned by you and its key expires in 180 days\n' "$bad"
  fi
}
