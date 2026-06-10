#!/usr/bin/env bash
set -euo pipefail

# Build the aarch64 Apple container-machine NixOS image on an x86_64 Linux
# Nix builder. The builder must have aarch64 binfmt/qemu enabled.

image_ref="${IMAGE_REF:-local/nixos-machine:latest}"
docker_archive="${DOCKER_ARCHIVE:-nixos-machine.tar.gz}"
oci_archive="${OCI_ARCHIVE:-nixos-machine-oci.tar}"
flake_attr="${FLAKE_ATTR:-.#packages.aarch64-linux.nixosContainerMachineImage}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

[ "$(uname -s)" = "Linux" ] || die "this script must run on Linux"
[ "$(uname -m)" = "x86_64" ] || die "this script must run on x86_64, got $(uname -m)"
need nix

echo "Building $flake_attr"
echo "Output image: $image_ref"

cd "$script_dir"
nix build --no-write-lock-file "$flake_attr"
cp -fL result "$docker_archive"

rm -f "$oci_archive"
nix shell nixpkgs#skopeo -c skopeo --insecure-policy copy \
  "docker-archive:$docker_archive" \
  "oci-archive:$oci_archive:$image_ref"

cat <<EOF
Built $oci_archive for $image_ref

Copy it to the Mac and load it:

  scp "$(hostname):$script_dir/$oci_archive" .
  container image load -i "$oci_archive"
  container machine create "$image_ref" --name nixos

If the build failed because aarch64-linux is unavailable, configure the builder
with binfmt/qemu and Nix extra-platforms first.
EOF
