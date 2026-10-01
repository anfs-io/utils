# tailscale

Installs the Tailscale client and ships **`tsm`** — a tailnet manager that joins this host
from a declarative config instead of a remembered `tailscale up` incantation.

```bash
ppm install tailscale
cp ~/.config/tailscale/config.example.yml ~/.config/tailscale/config.yml
tsm prereqs      # the one-time tailnet setup, and what can be checked from here
tsm join
```

## What a tailnet is, briefly

A tailnet is your private WireGuard mesh. Every device that joins gets a stable `100.x.y.z`
address and can reach every other device directly, punching through NAT where it can and
relaying through Tailscale's servers where it cannot. Joining is one command. The parts
worth understanding are *what identity a node joins as* and *what it advertises*.

### Tagged or user-owned — the fork that decides everything else

**User-owned** is what you get from a browser login. The node belongs to your account,
inherits your ACL permissions, and its key expires every 180 days, at which point it drops
off the tailnet until a human re-authenticates. Right for a laptop.

**Tagged** (`tags:` in the config) means the node belongs to the tailnet, not to a person.
Key expiry is disabled, so it never silently falls off; ACLs address it by tag, so "all
servers can reach the NFS box" is one rule rather than a list of hostnames. Right for
anything headless. The cost is one line in the tailnet policy file declaring who may apply
the tag — a tag missing from `tagOwners` is rejected at join time.

## Credentials: use an OAuth client, not an auth key

Tailscale auth keys **expire after at most 90 days and cannot be made permanent**. A
"long-lived key" parked in 1Password will break onboarding four times a year, and always at
the moment you are trying to bring up a new host.

An **OAuth client** does not expire, and its client secret can be handed straight to
`--auth-key`. `tsm` recognises both and tells you which you have. The one constraint: an
OAuth secret can only ever create a *tagged* node, so the config must declare `tags:` —
`tsm` refuses the combination rather than letting Tailscale return an opaque error.

The secret lives in 1Password and is resolved by `fnox`. On a remote host that works
because `pde/op` forwards a 1Password service account token over the SSH connection; see
that package's README. `tsm` re-execs itself under `fnox exec` when a `fnox.toml` sits
beside the config, so the key is present without ever being exported into your shell.

## Not losing your SSH session

You onboard a remote host over ordinary SSH, and two config keys can cut the branch you are
sitting on:

- **`exit_node`** routes *all* of this node's traffic through another node, including the
  path your session is using.
- **`accept_routes`** is subtler. If any subnet router in the tailnet advertises a range
  covering the address you are connected over, that traffic is pulled into the tailnet and
  the session dies. Tailscale does not fall back to a less specific route.

Everything else is safe. A plain join adds the `tailscale0` interface and routes for
`100.64.0.0/10` only; it does not touch your default route or existing connections. Even
`advertise_exit_node` is safe — advertising is a declaration, not a change to this node's
own routing.

So `tsm` refuses to apply either dangerous key while `$SSH_CONNECTION` is set, unless you
pass `--yes`. Join without them first, then turn them on from a second path.

## Commands

| | |
|---|---|
| `tsm join` | Join the tailnet. Reconciles instead of re-authenticating if already joined. |
| `tsm set` | Apply config changes to a joined node, with no re-auth. |
| `tsm show` | The flags the config produces, secret masked. Safe to paste. |
| `tsm status` | `tailscale status` for this node. |
| `tsm prereqs` | The manual tailnet setup, plus three checks that run locally. |
| `tsm info` | Paths, binary, daemon state, credential kind, key-handoff mode. |

Flags: `-n/--dry-run` (print, touch nothing), `-y/--yes` (skip confirmations).

## The prerequisite gate

The tailnet-side setup cannot be done from the host being joined, and a join missing any
piece of it fails with an error that does not say which piece. So the first `tsm join` on a
host asks you to confirm, and caches the answer in `~/.cache/tsm/prereqs-ack`.

The ack carries a fingerprint of the tags, so re-pointing a host at a different tailnet asks
again while editing a hostname does not. `--yes` is the standing acknowledgement, and is what
makes unattended installs possible. With no TTY and no ack, `tsm` fails with instructions
rather than blocking on a prompt nobody can answer.

## Joining automatically on install

Opt in per machine, in `~/.config/ppm/ppm.local.conf` (uncommitted, machine-local):

```sh
TSM_AUTOJOIN=true
```

`post_install` then runs `tsm join --yes` whenever a `config.yml` exists. It is idempotent:
a second `ppm install` reconciles settings rather than re-authenticating.

## Configuration

`~/.config/tailscale/config.yml`. Every key is optional and an unset key is not passed at
all. See `config.example.yml` for the annotated version.

```yaml
hostname: web1            # MagicDNS name: web1.<tailnet>.ts.net
tags: [tag:server]        # tagged node; required for an OAuth credential
ssh: true                 # Tailscale SSH — needs a matching ACL rule
accept_dns: true
accept_routes: false      # dangerous over ssh; see above
advertise_routes: []      # safe; needs approval in the console
advertise_exit_node: false
exit_node: ""             # dangerous over ssh; see above
operator: ansible         # drive tailscaled without sudo
```

`tailscale up` does not persist flags between runs, so this file is the single source of
truth and `tsm` always passes the full set — an omitted flag would silently revert to a
default and the config would not mean what it says.

In the ppm layout the real `config.yml` normally comes from your `user` repo, so it is
versioned and reaches every host, while the generic package ships only the example.

### Why not tailscaled's own config file

`tailscaled --config` exists and is genuinely declarative, but it cannot do this job: it has
no `AdvertiseTags` field, which an OAuth join requires; it is `alpha0`; it configures the
daemon rather than the CLI, so it needs the vendor-owned systemd unit edited and re-edited
after upgrades; and its `authKey` would put the secret on disk in plaintext.

## Platform notes

**Linux** keeps the vendor installer (`curl | sh`). It adds Tailscale's repo and signing key
and sets up the `tailscaled` systemd unit — none of which ppm's `brew`/`cask`/`system`
vocabulary can express. `install_linux` gates on the binary being absent, then enables the
unit separately, so a merely *stopped* daemon is started rather than reinstalled.

**macOS** gets the `tailscale-app` cask. It has no `binary` stanza, so nothing lands on
PATH; `tsm` resolves the CLI inside the bundle by absolute path, and `tailscale.zsh` defines
a shell function so `tailscale` and its completions work interactively.

## Testing

```bash
bats packages/tailscale/tests/tsm.bats
```

24 tests, offline and sub-second: `tailscale` and `fnox` are stubs and every run is
sandboxed to a temp HOME. Nothing touches a tailnet, 1Password or the network.
