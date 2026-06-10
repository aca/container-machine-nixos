#!/usr/bin/env bash
set -euo pipefail

machine_name="${1:-nixos}"
image_ref="local/nixos-machine:latest"
archive_name="nixos-machine.tar.gz"
oci_archive_name="nixos-machine-oci.tar"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v orb >/dev/null 2>&1; then
  echo "orb is required because the NixOS image must be built on Linux." >&2
  exit 1
fi

if ! command -v container >/dev/null 2>&1; then
  echo "container CLI is required." >&2
  exit 1
fi

orb -m tsvm sh -lc "cd '$script_dir' && nix build .#nixosContainerMachineImage"
orb -m tsvm sh -lc "cd '$script_dir' && cp -fL result '$archive_name'"
orb -m tsvm sh -lc "cd '$script_dir' && rm -f '$oci_archive_name' && nix shell nixpkgs#skopeo -c skopeo --insecure-policy copy docker-archive:'$archive_name' oci-archive:'$oci_archive_name':'$image_ref'"

container image load -i "$script_dir/$oci_archive_name"

if container machine inspect "$machine_name" >/dev/null 2>&1; then
  echo "Machine '$machine_name' already exists."
else
  container machine create "$image_ref" --name "$machine_name"
fi

cat <<EOF
Loaded $image_ref

Run:
  container machine run -n $machine_name

Run as root:
  container machine run -n $machine_name --root
EOF
