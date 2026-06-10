#!/usr/bin/env bash
set -euo pipefail

machine_name="${1:-nixos}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CREATE_MACHINE=1 MACHINE_NAME="$machine_name" \
  "$script_dir/build-nixos-machine-on-mac.sh"
