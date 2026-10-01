#!/usr/bin/env bats
# tsm — offline tests. Nothing here touches a tailnet, 1Password or the network:
# `tailscale` and `fnox` are stubs on PATH, and every run is sandboxed to a temp HOME.
#
#   bats packages/tailscale/tests/tsm.bats

setup() {
  PKG="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TSM="$PKG/home/.local/bin/tsm"

  export TMP="$BATS_TEST_TMPDIR"
  export XDG_CONFIG_HOME="$TMP/config"
  export XDG_CACHE_HOME="$TMP/cache"
  export TSM_LIB="$PKG/home/.local/lib/tsm"
  mkdir -p "$XDG_CONFIG_HOME/tailscale" "$TMP/bin"

  export PATH="$TMP/bin:$PATH"
  export TAILSCALE_BIN="$TMP/bin/tailscale"
  export TS_AUTHKEY="tskey-client-TESTSECRET"

  stub_tailscale NeedsLogin
  write_config
}

# A stub that records its argv so tests can assert on what tsm actually ran.
stub_tailscale() {
  local state="${1:-NeedsLogin}"
  cat > "$TMP/bin/tailscale" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/argv.log"
case "\$1 \$2" in "status --json") echo '{"BackendState":"$state"}'; exit 0 ;; esac
case "\$1" in
  version) echo "1.80.0"; exit 0 ;;
  status)  if [ "$state" = NeedsLogin ]; then echo "Logged out."; exit 1; else echo "100.1.2.3 box"; exit 0; fi ;;
  debug)   exit 1 ;;
  up)      [ "\$2" = --help ] && { echo "--auth-key string   value, or file: path"; exit 0; }; exit 0 ;;
  set)     exit 0 ;;
esac
exit 0
EOF
  chmod +x "$TMP/bin/tailscale"
}

write_config() {
  cat > "$XDG_CONFIG_HOME/tailscale/config.yml" <<EOF
hostname: ${1:-testbox}
tags: [${2-tag:server}]
ssh: true
accept_dns: true
accept_routes: ${3:-false}
exit_node: "${4:-}"
EOF
}

ack() { "$TSM" join --yes </dev/null >/dev/null 2>&1 || true; }

# --- flag translation ------------------------------------------------------

@test "config keys become tailscale flags" {
  run "$TSM" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"--hostname=testbox"* ]]
  [[ "$output" == *"--advertise-tags=tag:server"* ]]
  [[ "$output" == *"--ssh=true"* ]]
}

@test "booleans are emitted explicitly, since tailscale up does not persist flags" {
  run "$TSM" show
  [[ "$output" == *"--accept-routes=false"* ]]
}

@test "tags are join-only and never reach tailscale set" {
  run "$TSM" show
  local setline; setline="$(echo "$output" | grep '^set:')"
  [[ "$setline" != *"advertise-tags"* ]]
}

@test "an unset key is not passed at all" {
  printf 'hostname: bare\n' > "$XDG_CONFIG_HOME/tailscale/config.yml"
  run "$TSM" show
  [[ "$output" != *"--ssh"* ]]
  [[ "$output" != *"--accept-routes"* ]]
}

@test "a misspelled key is reported rather than silently ignored" {
  printf 'hostname: x\naccept-routes: true\n' > "$XDG_CONFIG_HOME/tailscale/config.yml"
  run "$TSM" show
  [[ "$output" == *"unknown key(s)"* ]]
  [[ "$output" == *"accept-routes"* ]]
}

# --- the credential --------------------------------------------------------

@test "the key never appears in argv when the CLI accepts file:" {
  ack
  rm -f "$TMP/argv.log"
  run "$TSM" join --yes
  [ "$status" -eq 0 ]
  run grep -c TESTSECRET "$TMP/argv.log"
  [ "$output" = "0" ]
}

@test "an OAuth secret with no tags is refused, because it can only tag" {
  write_config testbox "" false
  run "$TSM" join --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"only create a tagged node"* ]]
}

@test "a plain auth key warns about the 90-day cap" {
  export TS_AUTHKEY="tskey-auth-SOMETHING"
  ack
  run "$TSM" join --yes
  [[ "$output" == *"90 days"* ]]
}

@test "an unrecognised credential is rejected" {
  export TS_AUTHKEY="hunter2"
  ack
  run "$TSM" join --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a Tailscale key"* ]]
}

# --- the prerequisite gate -------------------------------------------------

@test "the first join is blocked until the prerequisites are acknowledged" {
  run "$TSM" join </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"prerequisites"* ]]
}

@test "no tty means fail with guidance, never block on a prompt" {
  # macOS has no timeout(1); coreutils installs it as gtimeout. Without either, the
  # assertion still holds — tsm checks [[ -t 0 ]] before any read, so it cannot hang —
  # the wrapper just turns a regression into a failure instead of a stuck suite.
  local t=""
  command -v timeout  >/dev/null && t=timeout
  [ -n "$t" ] || { command -v gtimeout >/dev/null && t=gtimeout; }

  if [ -n "$t" ]; then
    run "$t" 10 "$TSM" join </dev/null
    [ "$status" -ne 124 ]    # 124 means it blocked on read
  else
    run "$TSM" join </dev/null
  fi
  [ "$status" -eq 1 ]
  [[ "$output" == *"no terminal to ask on"* ]]
}

@test "--yes writes the ack and a second run does not ask" {
  ack
  [ -f "$XDG_CACHE_HOME/tsm/prereqs-ack" ]
  run "$TSM" join
  [ "$status" -eq 0 ]
  [[ "$output" != *"prerequisites"* ]]
}

@test "--dry-run writes no ack, because it promises to touch nothing" {
  run "$TSM" join --yes --dry-run
  [ ! -f "$XDG_CACHE_HOME/tsm/prereqs-ack" ]
}

@test "changing tailnet re-asks, but an ordinary config edit does not" {
  ack
  write_config renamed tag:server      # same tags, new hostname
  run "$TSM" join </dev/null
  [ "$status" -eq 0 ]

  write_config renamed tag:other       # different tailnet identity
  run "$TSM" join </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"prerequisites"* ]]
}

# --- not cutting off the branch you are sitting on -------------------------

@test "accept_routes over ssh is refused by default" {
  ack
  write_config testbox tag:server true
  SSH_CONNECTION="10.0.0.5 1 172.31.16.26 22" run "$TSM" join --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing"* ]]
}

@test "exit_node over ssh is refused by default" {
  ack
  write_config testbox tag:server false "100.9.9.9"
  SSH_CONNECTION="10.0.0.5 1 172.31.16.26 22" run "$TSM" join --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing"* ]]
}

@test "--yes overrides the guard but says so" {
  ack
  write_config testbox tag:server true
  SSH_CONNECTION="10.0.0.5 1 172.31.16.26 22" run "$TSM" join --yes --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"console access"* ]]
}

@test "the guard is silent when not connected over ssh" {
  ack
  write_config testbox tag:server true
  run env -u SSH_CONNECTION "$TSM" join --dry-run
  [ "$status" -eq 0 ]
}

# --- idempotency -----------------------------------------------------------

@test "an already-joined node reconciles instead of re-authenticating" {
  ack
  stub_tailscale Running
  rm -f "$TMP/argv.log"
  run "$TSM" join --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"already joined"* ]]
  run grep -c '^up ' "$TMP/argv.log"
  [ "$output" = "0" ]
  run grep -c '^set ' "$TMP/argv.log"
  [ "$output" != "0" ]
}

@test "a logged-out daemon is treated as reachable, not dead" {
  # `tailscale status` exits non-zero when logged out; under pipefail that once read
  # as a dead daemon, which would block the very first join.
  run "$TSM" info
  [[ "$output" == *"daemon:      responding"* ]]
}

# --- misc ------------------------------------------------------------------

@test "a missing config is an error that says how to fix it" {
  rm -f "$XDG_CONFIG_HOME/tailscale/config.yml"
  run "$TSM" show
  [ "$status" -ne 0 ]
  [[ "$output" == *"config.example.yml"* ]]
}

@test "prereqs runs without a config and without a tailnet" {
  rm -f "$XDG_CONFIG_HOME/tailscale/config.yml"
  run "$TSM" prereqs
  [ "$status" -eq 0 ]
  [[ "$output" == *"tagOwners"* ]]
}

@test "prereqs names the ssh ACL only when ssh is on" {
  run "$TSM" prereqs
  [[ "$output" == *"Grant SSH access"* ]]
  printf 'hostname: x\ntags: [tag:server]\nssh: false\n' > "$XDG_CONFIG_HOME/tailscale/config.yml"
  run "$TSM" prereqs
  [[ "$output" != *"Grant SSH access"* ]]
}

@test "an unknown command fails rather than doing something surprising" {
  run "$TSM" frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
}
