#!/usr/bin/env bash
set -euo pipefail

# Build the aarch64 Apple container-machine NixOS image on a native arm64 Linux
# Nix builder. This is the script used by the GHCR GitHub Action.

image_ref="${IMAGE_REF:-local/nixos-machine:latest}"
target_image_ref="${1:-${DOCKER_IMAGE_REF:-}}"
docker_archive="${DOCKER_ARCHIVE:-nixos-machine.tar.gz}"
oci_archive="${OCI_ARCHIVE:-nixos-machine-oci.tar}"
flake_attr="${FLAKE_ATTR:-.#packages.aarch64-linux.nixosContainerMachineImage}"
build_oci="${BUILD_OCI:-0}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

load_into_docker() {
  need docker
  docker info >/dev/null 2>&1 ||
    die "docker daemon is not reachable. Start Docker or fix Docker permissions"

  docker load -i "$docker_archive"

  if [ "$target_image_ref" != "$image_ref" ]; then
    docker tag "$image_ref" "$target_image_ref"
  fi

  docker image inspect "$target_image_ref" >/dev/null

  if [ "${PUSH:-0}" = "1" ]; then
    docker push "$target_image_ref"
  else
    echo "Loaded Docker image: $target_image_ref"
    echo "Push it with: docker push $target_image_ref"
  fi
}

[ "$(uname -s)" = "Linux" ] || die "this script must run on Linux"
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "this script must run on arm64/aarch64, got $(uname -m)" ;;
esac
need nix

echo "Building $flake_attr"
echo "Archive image tag: $image_ref"

cd "$script_dir"
nix build --no-write-lock-file "$flake_attr"
cp -fL result "$docker_archive"
echo "Built Docker archive: $docker_archive"

if [ "$build_oci" = "1" ]; then
  rm -f "$oci_archive"
  nix shell nixpkgs#skopeo -c skopeo --insecure-policy copy \
    "docker-archive:$docker_archive" \
    "oci-archive:$oci_archive:$image_ref"
  echo "Built OCI archive: $oci_archive"
fi

if [ -n "$target_image_ref" ]; then
  load_into_docker
fi
