# NixOS container machine

This builds a NixOS-based image for Apple `container machine`.

The Ubuntu `Dockerfile` can be built directly by `container build`, but the
NixOS image is built by Nix because the root filesystem must contain the NixOS
system closure and `/sbin/init`. The helper script builds a Docker archive with
Nix, converts it to an OCI archive with `skopeo`, and loads it into Apple
`container`.

## Build and create

### Build with the local macOS OrbStack helper

Build the image in the default OrbStack NixOS environment and load it into Apple
`container image` as `local/nixos-machine:latest`:

```sh
./build-nixos-machine-on-mac.sh
container image list
```

Build, load, and create a container machine named `nixos`:

```sh
./build-nixos-machine-on-mac.sh --create nixos
```

Verify the locally loaded image with a disposable `nixos-local-test` machine:

```sh
./verify-nixos-machine-local.sh
```

Use a different image tag when needed:

```sh
IMAGE_REF=local/nixos-machine:dev ./build-nixos-machine-on-mac.sh
```

The older shortcut still builds, loads, and creates the machine:

```sh
./build-nixos-machine.sh nixos-dev
```

### Build on an x86_64 Nix Linux machine

OrbStack is only a convenient Linux builder. Any x86_64 Linux machine with Nix
can build this aarch64 image if it can run aarch64 binaries through binfmt/qemu.

On a NixOS builder, enable aarch64 emulation once:

```nix
# /etc/nixos/configuration.nix
{
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  nix.settings.extra-platforms = [ "x86_64-linux" "aarch64-linux" ];
}
```

Then switch the builder:

```sh
sudo nixos-rebuild switch
```

On a non-NixOS Linux builder, install qemu/binfmt with the distro package
manager and allow Nix to schedule aarch64 builds. For Debian/Ubuntu-style
machines:

```sh
sudo apt-get update
sudo apt-get install -y qemu-user-static binfmt-support
sudo update-binfmts --enable qemu-aarch64

sudo mkdir -p /etc/nix
printf '\nextra-platforms = x86_64-linux aarch64-linux\n' | \
  sudo tee -a /etc/nix/nix.conf
sudo systemctl restart nix-daemon
```

Copy this repository to the x86_64 builder:

```sh
builder=x86-nix
remote_dir=/tmp/nixos-container-machine

rsync -a --delete \
  --exclude result \
  --exclude '*.tar' \
  --exclude '*.tar.gz' \
  ./ "$builder:$remote_dir/"
```

On the x86_64 builder, run:

```sh
cd /tmp/nixos-container-machine
./build-nixos-machine-on-x86.sh
```

The script builds `.#packages.aarch64-linux.nixosContainerMachineImage`, copies
the Docker archive to `nixos-machine.tar.gz`, converts it to
`nixos-machine-oci.tar`, and tags it as `local/nixos-machine:latest`.

Copy the OCI archive back to the Mac and load it into Apple `container`:

```sh
builder=x86-nix
remote_dir=/tmp/nixos-container-machine
image_ref=local/nixos-machine:latest

scp "$builder:$remote_dir/nixos-machine-oci.tar" .
container image load -i nixos-machine-oci.tar
container machine create "$image_ref" --name nixos
```

If the builder is not configured with `extra-platforms`, the build usually
fails with a message saying that an `aarch64-linux` machine is required. If
binfmt/qemu is missing, the build reaches an aarch64 binary and fails with an
exec format error.

### Build and push on an arm64 Linux machine

To push the same aarch64 image to a Docker registry, build it on a native
arm64/aarch64 Linux builder and load it into the builder's Docker daemon:

```sh
cd /tmp/nixos-container-machine
./build-nixos-machine-on-arm.sh ghcr.io/example/container-machine-nixos:26.05
```

After the script finishes, push the tag:

```sh
docker push ghcr.io/example/container-machine-nixos:26.05
```

Or push directly from the script:

```sh
PUSH=1 ./build-nixos-machine-on-arm.sh ghcr.io/example/container-machine-nixos:26.05
```

Log in to the registry first when needed:

```sh
docker login ghcr.io
```

### Publish with GitHub Actions

The repository includes `.github/workflows/publish-ghcr.yml`. It runs on the
GitHub-hosted ARM runner `ubuntu-24.04-arm`, builds the aarch64 image natively,
loads it into Docker with `build-nixos-machine-on-arm.sh`, and pushes it to
GHCR.

For this remote:

```text
https://github.com/aca/container-machine-nixos
```

the published image is:

```text
ghcr.io/aca/container-machine-nixos
```

Pushes to `main` publish:

```text
ghcr.io/aca/container-machine-nixos:latest
ghcr.io/aca/container-machine-nixos:26.05
ghcr.io/aca/container-machine-nixos:sha-<commit>
```

Git tags publish:

```text
ghcr.io/aca/container-machine-nixos:<tag>
ghcr.io/aca/container-machine-nixos:sha-<commit>
```

The workflow can also be run manually from the GitHub Actions tab with an
extra tag input.

## Connect

```sh
container machine run -n nixos
container machine run -n nixos --root
```

If `container machine run` fails with `Operation not supported by device` while
you are in a macOS project directory, run from `/` inside the guest:

```sh
container machine run -n nixos -w / 'id; pwd'
```

## Rebuild inside the machine

The machine keeps its NixOS configuration at `/etc/nixos/flake.nix`. Enter as
root, edit that file, then switch to the new generation:

```sh
container machine run -n nixos --root
vim /etc/nixos/flake.nix
nixos-rebuild switch --flake /etc/nixos#nixos --no-reexec
```

Run the same rebuild from macOS without opening an interactive shell:

```sh
container machine run -n nixos --root -- \
  'nixos-rebuild switch --flake /etc/nixos#nixos --no-reexec'
```

Use `--no-reexec` here because this image is booted by Apple `container machine`
instead of the normal NixOS bootloader/init flow.

Check the active state version and current generation:

```sh
container machine run -n nixos --root -- \
  'nix eval --raw /etc/nixos#nixosConfigurations.nixos.config.system.stateVersion; echo; readlink -f /run/current-system'
```

## Run macOS commands

The image includes a `mac` wrapper. It runs commands on the macOS host through
SSH to the container-machine gateway, `192.168.64.1`, port `2222` by default:

```sh
container machine run -n nixos -- 'mac uname -s'
container machine run -n nixos -- 'mac sw_vers -productVersion'
```

Override the host or user when needed:

```sh
container machine run -n nixos -- \
  'MAC_USER=your-macos-user MAC_HOST=192.168.64.1 mac uname -s'
```

For non-interactive password auth, pass `MAC_PASSWORD`:

```sh
container machine run -n nixos -- \
  'MAC_USER=your-macos-user MAC_PASSWORD=... mac uname -s'
```

Important: on this machine, port `22` is currently owned by `OrbStack Helper`,
not by macOS `sshd`. A key in macOS `~/.ssh/authorized_keys` will not help when
the container connects to that OrbStack listener. This wrapper uses port `2222`
by default to avoid OrbStack's listener.

Check which process owns port 22 on macOS:

```sh
lsof -nP -iTCP:22 -sTCP:LISTEN
```

Start a temporary macOS sshd on port `2222`:

```sh
sudo /usr/sbin/sshd -p 2222
```

Allow the macOS user through the SSH access ACL if the server accepts the key
and then closes the connection:

```sh
sudo dseditgroup -o edit -a "$(id -un)" -t user com.apple.access_ssh
```

Make sure the guest private key is not group/world-readable:

```sh
container machine run -n nixos -- \
  'chmod 700 ~/.ssh; chmod 600 ~/.ssh/id_ed25519'
```

Then run:

```sh
container machine run -n nixos -- 'mac uname -s'
```

Without a reachable macOS sshd plus a valid key, agent identity, or
`MAC_PASSWORD`, SSH authentication fails.

## Benchmark

See [BENCHMARK.md](BENCHMARK.md) for a repeatable benchmark procedure comparing
OrbStack Linux machines against Apple `container machine`.

The image reference is:

```text
local/nixos-machine:latest
```

## Notes

- `build-nixos-machine-on-mac.sh` assumes `orb` enters a Linux environment with
  `nix`; `build-nixos-machine-on-x86.sh` and `build-nixos-machine-on-arm.sh` do
  not use OrbStack.
- `skopeo` is fetched transiently with `nix shell nixpkgs#skopeo`; it does not
  need to be installed globally.
- The image enables `sudo` without a password for local container-machine
  users, matching the development-oriented behavior expected from these
  machines.
- `system.stateVersion` is set to `26.05`. This is the NixOS state/default
  compatibility version, not the systemd package version.
- NixOS packages live under `/run/current-system/sw/bin`. The image only keeps
  minimal `/usr/bin` and `/bin` compatibility entries needed by Apple's
  `container machine` wrapper, such as `/bin/sh` and `/usr/bin/{id,cut,grep}`.
- `/etc/machine/create-user.sh` must point at an executable store path because
  Apple runs it before NixOS activation applies `/etc` mode metadata.
- The image includes systemd, dbus, OpenSSH, Nix, curl, wget, vim, iproute2,
  iputils, net-tools, procps, and common core utilities.
