#!/usr/bin/env bash
set -euo pipefail

# Build the aarch64 Apple container-machine NixOS image from macOS by using the
# default OrbStack Linux environment, then load the OCI image into Apple
# `container`.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

image_ref="${IMAGE_REF:-local/nixos-machine:latest}"
flake_attr="${FLAKE_ATTR:-.#packages.aarch64-linux.nixosContainerMachineImage}"
build_dir="${BUILD_DIR:-.container-machine-build}"
docker_archive_name="${DOCKER_ARCHIVE:-nixos-machine.tar.gz}"
oci_archive_name="${OCI_ARCHIVE:-nixos-machine-oci.tar}"
create_machine="${CREATE_MACHINE:-0}"
machine_name="${MACHINE_NAME:-nixos}"

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

quote() {
  printf "%q" "$1"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--create [machine-name]] [--name machine-name]

Build with Nix inside the default OrbStack Linux environment and load the
resulting image into Apple container's local image store.

Environment:
  IMAGE_REF         Image reference loaded into container image (default: local/nixos-machine:latest)
  FLAKE_ATTR        Nix flake package to build (default: .#packages.aarch64-linux.nixosContainerMachineImage)
  BUILD_DIR         Local output directory, relative to this repo unless absolute (default: .container-machine-build)
  CREATE_MACHINE=1  Create the container machine after loading the image
  MACHINE_NAME      Machine name used with CREATE_MACHINE=1 (default: nixos)

Examples:
  $(basename "$0")
  $(basename "$0") --create nixos
  IMAGE_REF=local/nixos-machine:dev $(basename "$0")
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --create)
      create_machine=1
      shift
      if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
        machine_name="$1"
        shift
      fi
      ;;
    --name)
      [ "$#" -ge 2 ] || die "--name requires a value"
      machine_name="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "this script must run on macOS"
need orb
need container

case "$build_dir" in
  /*) ;;
  *) build_dir="$script_dir/$build_dir" ;;
esac

out_link="$build_dir/result"
docker_archive="$build_dir/$docker_archive_name"
oci_archive="$build_dir/$oci_archive_name"

script_dir_q="$(quote "$script_dir")"
build_dir_q="$(quote "$build_dir")"
out_link_q="$(quote "$out_link")"
docker_archive_q="$(quote "$docker_archive")"
oci_archive_q="$(quote "$oci_archive")"
flake_attr_q="$(quote "$flake_attr")"
docker_archive_arg_q="$(quote "docker-archive:$docker_archive")"
oci_archive_arg_q="$(quote "oci-archive:$oci_archive:$image_ref")"

echo "Builder: orb"
echo "Image:   $image_ref"
echo "Output:  $oci_archive"

orb sh -lc "
set -eu
command -v nix >/dev/null 2>&1 || {
  echo 'error: nix is required in the default OrbStack environment' >&2
  exit 1
}

cd $script_dir_q
mkdir -p $build_dir_q

echo 'Building $flake_attr'
nix build --no-write-lock-file --out-link $out_link_q $flake_attr_q
cp -fL $out_link_q $docker_archive_q

rm -f $oci_archive_q
nix shell nixpkgs#skopeo -c skopeo --insecure-policy copy \
  $docker_archive_arg_q \
  $oci_archive_arg_q
"

container image load -i "$oci_archive"
container image inspect "$image_ref" >/dev/null

echo "Loaded Apple container image: $image_ref"

if [ "$create_machine" = "1" ]; then
  if container machine inspect "$machine_name" >/dev/null 2>&1; then
    echo "Machine '$machine_name' already exists."
  else
    container machine create "$image_ref" --name "$machine_name"
  fi

  cat <<EOF

Run:
  container machine run -n $machine_name

Run as root:
  container machine run -n $machine_name --root
EOF
else
  cat <<EOF

Create a machine when needed:
  container machine create $image_ref --name nixos
EOF
fi
