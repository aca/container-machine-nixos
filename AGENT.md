# Agent Notes

This repository builds a NixOS-based image for Apple `container machine`.

## Repository Shape

- Main flake: `flake.nix`
- User docs: `README-nixos-machine.md`
- Bench docs: `BENCHMARK.md`
- Local OrbStack helper: `build-nixos-machine.sh`
- x86_64 Linux builder helper: `build-nixos-machine-on-x86.sh`
- arm64 Linux builder/GHCR helper: `build-nixos-machine-on-arm.sh`
- GHCR workflow: `.github/workflows/publish-ghcr.yml`
- Remote: `https://github.com/aca/container-machine-nixos`
- GHCR image: `ghcr.io/aca/container-machine-nixos`

Always run `git status --short` before editing. The worktree may contain user
changes; do not revert unrelated files.

## Core Design

`flake.nix` builds an `aarch64-linux` NixOS system and packages it with
`pkgs.dockerTools.buildLayeredImage`.

The image is for Apple Silicon container machines, so the target architecture is
`aarch64-linux` even when the builder is x86_64.

Important runtime details:

- `system.stateVersion` is set to `26.05`. This is the NixOS state/default
  compatibility version, not the actual systemd version.
- NixOS packages are exposed through `/run/current-system/sw/bin`.
- Do not mirror all of `/run/current-system/sw/bin/*` into `/usr/bin` or `/bin`.
  The image intentionally keeps only minimal compatibility links required by
  Apple's `container machine` wrapper.
- `/etc/machine/shell` repairs `PATH` for `container machine run` commands.
- `/etc/machine/create-user.sh` wraps Apple's user creation script with a NixOS
  PATH.
- `/sbin/init` prefers `/nix/var/nix/profiles/system` when present, so
  `nixos-rebuild switch` generations survive machine stop/start. It falls back
  to the baked image toplevel on first boot.

## Common Commands

From macOS with the OrbStack helper:

```sh
./build-nixos-machine.sh
```

On an x86_64 Linux Nix builder:

```sh
./build-nixos-machine-on-x86.sh
```

The x86_64 builder needs aarch64 emulation:

```nix
boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
nix.settings.extra-platforms = [ "x86_64-linux" "aarch64-linux" ];
```

Build a Docker-pushable image on arm64 Linux:

```sh
./build-nixos-machine-on-arm.sh ghcr.io/aca/container-machine-nixos:26.05
docker push ghcr.io/aca/container-machine-nixos:26.05
```

Or push directly:

```sh
PUSH=1 ./build-nixos-machine-on-arm.sh ghcr.io/aca/container-machine-nixos:26.05
```

Load an OCI archive into Apple `container`:

```sh
container image load -i nixos-machine-oci.tar
container machine create local/nixos-machine:latest --name nixos
```

Connect:

```sh
container machine run -n nixos
container machine run -n nixos --root
```

Rebuild inside the container machine:

```sh
container machine run -n nixos --root
vim /etc/nixos/flake.nix
nixos-rebuild switch --flake /etc/nixos#nixos --no-reexec
```

Use `--no-reexec` because Apple `container machine` does not boot through the
normal NixOS bootloader/init flow.

## GitHub Actions

`.github/workflows/publish-ghcr.yml` publishes the image to GHCR.

It uses the GitHub-hosted ARM runner:

```yaml
runs-on: ubuntu-24.04-arm
```

For public repositories, this standard ARM runner is free to use. The workflow
uses `GITHUB_TOKEN` with `packages: write` and pushes:

- `ghcr.io/aca/container-machine-nixos:latest` on `main`
- `ghcr.io/aca/container-machine-nixos:26.05` on `main`
- `ghcr.io/aca/container-machine-nixos:sha-<commit>`
- `ghcr.io/aca/container-machine-nixos:<tag>` for git tags

Run local static checks before committing workflow/script changes:

```sh
bash -n build-nixos-machine-on-x86.sh
bash -n build-nixos-machine-on-arm.sh
nix shell nixpkgs#actionlint -c actionlint ../.github/workflows/publish-ghcr.yml
```

## mac Wrapper

The NixOS image includes a `mac` command that SSHes back to the macOS host.

Defaults:

- Host: `192.168.64.1`
- Port: `2222`
- User: inferred from the injected container user, or `MAC_USER`

Port `22` may be owned by OrbStack Helper on this machine, so do not assume
macOS `sshd` is listening there. For container-machine host command execution,
use a separate macOS `sshd` on port `2222` or a launchd daemon that runs:

```sh
/usr/sbin/sshd -D -e -p 2222
```

If SSH accepts the key and then closes the connection, the macOS user may need
to be added to the SSH ACL:

```sh
sudo dseditgroup -o edit -a kyungrok.chung -t user com.apple.access_ssh
```

## Validation Notes

Useful checks:

```sh
nix flake check
bash -n build-nixos-machine-on-x86.sh
bash -n build-nixos-machine-on-arm.sh
```

Full image builds are expensive. Prefer syntax/static checks unless the user
explicitly asks to build.

When testing GitHub Actions locally, use `actionlint`; do not assume the runner
environment is identical to macOS.
