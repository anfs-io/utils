# utils-ppm

Utility packages for [ppm](https://github.com/maxcole/ppm), covering the things that are
neither a development environment nor a language toolchain: networking, storage, and the
tools for putting an operating system onto hardware.

Installed like any other ppm repo:

```bash
ppm install utils/tailscale     # one package
ppm install utils/              # the lot
```

This repo sits above `ai`, `pdt`, `pde` and `ppm` in source priority and below your `user`
repo — so a package here can depend on one from `pde`, and your own repo can layer host- or
tailnet-specific config over anything here without forking it.

## Packages

| Package | Platforms | What it does |
|---|---|---|
| [tailscale](packages/tailscale/README.md) | macOS, Linux | Tailscale client plus `tsm`, which joins a host to a tailnet from a declarative config instead of a remembered `tailscale up` incantation. Credentials come from 1Password via fnox. |
| [rpi-imager](packages/rpi-imager) | macOS | Writes a Raspberry Pi card from a declarative cloud-init profile — raw `user-data` and `network-config` plus a small `image.yml`, with secrets resolved from the environment. |
| [ventoy](packages/ventoy) | Linux (writer), macOS (copy) | Ventoy multiboot USB manager, with a wrapper that downloads ISOs from a declared list. |
| [nfs](packages/nfs) | macOS, Linux | Serves NFS exports on Linux (`nfs-kernel-server`) and mounts them on macOS through its built-in autofs. Driven by config in `~/.config/nfs/`. |
| [network-tools](packages/network-tools) | macOS, Linux | `iperf3`, `nmap`, `bandwhich`, and a `netperf` helper for comparing a tailnet path against the underlying LAN. |
| [mosh](packages/mosh) | macOS, Linux | Mosh, for shells that survive a roaming or flaky connection. |
| [gam](packages/gam/README.md) | macOS, Linux | GAM, the Google Workspace admin CLI. |
| [hammerspoon](packages/hammerspoon) | macOS | Hammerspoon plus its Spoons, for macOS window and input automation. |

Packages without a README are small enough to read directly: `package.yml` declares the
software, `install.sh` holds anything imperative, and `home/` is the stow tree.

## Conventions

These follow the repo-wide ppm conventions — see
[ppm's CLAUDE.md](https://github.com/maxcole/ppm/blob/main/CLAUDE.md) for the full spec.
Two worth knowing when reading these packages:

- **Software is declared, not installed.** `package.yml` lists `brew` / `cask` / `system`
  packages and ppm installs them before any hook runs. An `install.sh` hook is for the
  things that vocabulary cannot express: third-party apt repos, systemd units, vendor
  installers, GitHub release tarballs.
- **Config presence is the signal.** A package ships `something.example` in its stow tree
  and acts only when the real file exists, printing guidance when it does not. That is what
  lets your `user` repo supply the real config without the generic package knowing anything
  about your setup.

## Testing

Packages with non-trivial scripts carry offline [bats](https://github.com/bats-core/bats-core)
suites that stub every external command:

```bash
bats packages/tailscale/tests/tsm.bats
```
